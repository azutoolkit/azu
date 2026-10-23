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

      # An RFC 9457 problem document (`application/problem+json`).
      def problem? : Bool
        content_type == "application/problem+json"
      end
    end
  end
end
