require "json"

module Azu
  module Testing
    # What a `Client` got back: a value, fully read.
    struct Response
      getter status : HTTP::Status
      getter headers : HTTP::Headers
      getter body : String
      # The exception that escaped the handler chain, which a real server answers with a bare 500.
      getter error : Exception?

      REDIRECTS = {301, 302, 303, 307, 308}

      def initialize(@status : HTTP::Status, @headers : HTTP::Headers, @body : String, @error : Exception? = nil)
      end

      def status_code : Int32
        status.code
      end

      def success? : Bool
        status.success?
      end

      def redirect? : Bool
        REDIRECTS.includes?(status_code) && headers.has_key?("Location")
      end

      def location : String?
        headers["Location"]?
      end

      def header(name : String) : String?
        headers[name]?
      end

      def content_type : String?
        headers["Content-Type"]?.try(&.split(';').first.strip)
      end

      # The cookies the response sets.
      def cookies : HTTP::Cookies
        HTTP::Cookies.from_server_headers(headers)
      end

      def json : JSON::Any
        JSON.parse(body)
      end

      def json(type : T.class) : T forall T
        T.from_json(body)
      end

      # An RFC 9457 problem document: sent as `application/problem+json`, or as JSON whose body has the members of
      # one (string `type` and `title`, and a `status` that is the response's own, 400 or above). Azu labels the body `problem+json` only for a client whose `Accept`
      # names it, so the content type alone would miss the problem bodies of a client that asked for `application/json`.
      def problem? : Bool
        return true if content_type == "application/problem+json"
        return false unless content_type.try { |type| type == "application/json" || type.ends_with?("+json") }

        document = JSON.parse(body).as_h? || return false
        {"type", "title"}.all? { |member| !document[member]?.try(&.as_s?).nil? } && document["status"]?.try(&.as_i64?) == status_code && status_code >= 400
      rescue JSON::ParseException
        false
      end
    end
  end
end
