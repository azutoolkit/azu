require "http"
require "json"

module Azu
  # Helpers for testing an Azu app without starting a server. Requests go through the
  # real router and handler stack, so routing, params, hooks, sessions and error pages
  # behave as in production.
  #
  # ```
  # require "azu/testing"
  #
  # describe CreateUser do
  #   client = Azu::Test::Client.new
  #
  #   it "creates a user" do
  #     response = client.post "/users", json: {email: "ana@example.com", name: "Ana"}
  #     response.status.should eq HTTP::Status::CREATED
  #     response.json["email"].as_s.should eq "ana@example.com"
  #   end
  #
  #   it "rejects bad input" do
  #     client.post("/users", json: {email: "nope"}).status.should eq HTTP::Status::UNPROCESSABLE_ENTITY
  #   end
  # end
  # ```
  #
  # A client keeps cookies between requests, so sign-in flows and flash messages work:
  # `client.post "/login", form: {...}; client.get "/dashboard"`.
  module Test
    # The result of a test request.
    class Response
      getter status : HTTP::Status
      getter headers : HTTP::Headers
      getter body : String

      def initialize(@status : HTTP::Status, @headers : HTTP::Headers, @body : String)
      end

      def status_code : Int32
        status.code
      end

      # True for any 2xx status.
      def success? : Bool
        status.success?
      end

      def redirect? : Bool
        status.redirection?
      end

      # The `Location` header of a redirect.
      def location : String?
        headers["Location"]?
      end

      # The body parsed as JSON.
      def json : JSON::Any
        JSON.parse(body)
      end

      # The body parsed into *type* (any `JSON::Serializable`).
      def json(type : T.class) : T forall T
        T.from_json(body)
      end

      def content_type : String?
        headers["Content-Type"]?.try(&.split(';').first.strip)
      end

      # Name => value of the cookies the response set.
      def cookies : Hash(String, String)
        jar = Hash(String, String).new
        HTTP::Cookies.from_server_headers(headers).each { |cookie| jar[cookie.name] = cookie.value }
        jar
      end
    end

    # Sends requests to an app through its router (and optional handlers) in-process.
    class Client
      # Handlers wrapped around the router; `Azu::Handler::Rescuer` by default so errors
      # become the same responses a browser would see.
      getter handlers : Array(HTTP::Handler)
      getter router : Router
      getter cookies = Hash(String, String).new
      getter headers = HTTP::Headers.new

      def initialize(@router : Router = CONFIG.router, handlers : Array(HTTP::Handler)? = nil)
        @handlers = handlers || [Azu::Handler::Rescuer.new] of HTTP::Handler
      end

      # Sends *name*: *value* with every request, e.g. `client.header "Authorization", "Bearer x"`.
      def header(name : String, value : String) : self
        headers[name] = value
        self
      end

      {% for verb in %w(get head delete options) %}
        # Sends a {{verb.upcase.id}} request. *params* are added to the query string.
        def {{verb.id}}(path : String, params : Hash | NamedTuple | Nil = nil, headers : Hash(String, String) = {} of String => String) : Response
          request("{{verb.upcase.id}}", with_query(path, params), nil, headers)
        end
      {% end %}

      {% for verb in %w(post put patch) %}
        # Sends a {{verb.upcase.id}} request with a JSON body (`json:`), a URL-encoded
        # form (`form:`) or a raw `body:`.
        def {{verb.id}}(path : String, json = nil, form : Hash | NamedTuple | Nil = nil, body : String? = nil, headers : Hash(String, String) = {} of String => String) : Response
          send_body("{{verb.upcase.id}}", path, json, form, body, headers)
        end
      {% end %}

      # Sends any request.
      def request(method : String, path : String, body : String? = nil, headers : Hash(String, String) = {} of String => String) : Response
        request_headers = self.headers.dup
        headers.each { |name, value| request_headers[name] = value }
        unless cookies.empty?
          request_headers["Cookie"] = cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
        end

        request = HTTP::Request.new(method, path, request_headers, body)
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        entry = HTTP::Server.build_middleware(handlers.dup, ->(ctx : HTTP::Server::Context) { router.process(ctx) })
        entry.call(context)
        response.close

        io.rewind
        parsed = HTTP::Client::Response.from_io(io, ignore_body: method == "HEAD")
        remember_cookies(parsed.headers)
        Response.new(parsed.status, parsed.headers, parsed.body)
      end

      private def send_body(method : String, path : String, json, form, body : String?, headers : Hash(String, String)) : Response
        headers = headers.dup
        payload = if !json.nil?
                    headers["Content-Type"] ||= "application/json"
                    headers["Accept"] ||= "application/json"
                    json.to_json
                  elsif form
                    headers["Content-Type"] ||= "application/x-www-form-urlencoded"
                    HTTP::Params.encode(form.to_h.transform_keys(&.to_s).transform_values(&.to_s))
                  else
                    body
                  end
        request(method, path, payload, headers)
      end

      private def with_query(path : String, params) : String
        return path unless params
        query = HTTP::Params.encode(params.to_h.transform_keys(&.to_s).transform_values(&.to_s))
        query.empty? ? path : "#{path}#{path.includes?('?') ? '&' : '?'}#{query}"
      end

      private def remember_cookies(response_headers : HTTP::Headers) : Nil
        HTTP::Cookies.from_server_headers(response_headers).each do |cookie|
          if cookie.value.empty? || cookie.max_age.try(&.<=(Time::Span.zero))
            cookies.delete(cookie.name)
          else
            cookies[cookie.name] = cookie.value
          end
        end
      end
    end
  end
end
