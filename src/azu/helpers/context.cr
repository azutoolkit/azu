require "http"
require "uri"

module Azu
  module Helpers
    # TemplateContext wraps the HTTP server context for use in templates.
    #
    # This class provides convenient access to request information, flash messages,
    # session data, cookies, and CSRF tokens within Crinja templates.
    #
    # ## Usage
    #
    # TemplateContext is automatically created and injected when rendering views
    # via the `Renderable` module. It provides access to:
    #
    # - Current request path and URL
    # - Query parameters
    # - Cookies
    # - Flash messages
    # - Session data
    # - CSRF tokens
    #
    # ## Example
    #
    # In templates:
    #
    # ```jinja
    # <p>Current path: {{ current_path }}</p>
    # <p>CSRF Token: {{ csrf_token }}</p>
    # {% if flash.notice %}
    #   <div class="alert">{{ flash.notice }}</div>
    # {% endif %}
    # ```
    class TemplateContext
      getter context : HTTP::Server::Context
      getter request : HTTP::Request
      getter response : HTTP::Server::Response
      getter params : HTTP::Params
      getter cookies : HTTP::Cookies

      @flash : Hash(String, String)?
      @session : Hash(String, String)?

      def initialize(@context : HTTP::Server::Context)
        @request = @context.request
        @response = @context.response
        @params = @request.query_params
        @cookies = HTTP::Cookies.from_client_headers(@request.headers)
      end

      # Returns the current request path.
      #
      # ```
      # ctx.current_path # => "/users/123"
      # ```
      def current_path : String
        @request.path
      end

      # Returns the full current URL.
      #
      # ```
      # ctx.current_url # => "https://example.com/users/123?page=1"
      # ```
      def current_url : String
        "#{scheme}://#{host}#{@request.resource}"
      end

      # Returns the request scheme (http or https).
      def scheme : String
        @request.headers["X-Forwarded-Proto"]? || "http"
      end

      # Returns the request host.
      def host : String
        @request.headers["Host"]? || "localhost"
      end

      # Returns the HTTP method.
      def method : String
        @request.method
      end

      # Returns the request body as string.
      def body : String?
        @request.body.try(&.gets_to_end)
      end

      # Check if the request is an AJAX request.
      def ajax? : Bool
        @request.headers["X-Requested-With"]? == "XMLHttpRequest"
      end

      # Check if the request is a secure (HTTPS) request.
      def secure? : Bool
        scheme == "https"
      end

      # Returns flash messages from cookie.
      #
      # Flash messages are typically set after redirects to display
      # one-time notifications.
      #
      # ```jinja
      # {% if flash.notice %}
      #   <div class="alert alert-success">{{ flash.notice }}</div>
      # {% endif %}
      # {% if flash.error %}
      #   <div class="alert alert-danger">{{ flash.error }}</div>
      # {% endif %}
      # ```
      def flash : Hash(String, String)
        @flash ||= extract_flash
      end

      # Returns session data.
      #
      # Session data is extracted from cookies and decoded.
      def session : Hash(String, String)
        @session ||= extract_session
      end

      # Returns CSRF token for the current request.
      #
      # ```jinja
      # <input type="hidden" name="_csrf" value="{{ csrf_token }}" />
      # ```
      def csrf_token : String
        Handler::CSRF.token(@context)
      end

      # Returns CSRF hidden input tag.
      #
      # ```jinja
      # {{ csrf_tag }}
      # ```
      def csrf_tag : String
        Handler::CSRF.tag(@context)
      end

      # Returns CSRF meta tag for AJAX requests.
      #
      # ```jinja
      # {{ csrf_metatag }}
      # ```
      def csrf_metatag : String
        Handler::CSRF.metatag(@context)
      end

      # Returns the referer URL.
      def referer : String?
        @request.headers["Referer"]?
      end

      # Returns the user agent string.
      def user_agent : String?
        @request.headers["User-Agent"]?
      end

      # Returns the client IP address.
      def client_ip : String?
        @request.headers["X-Forwarded-For"]?.try(&.split(",").first.strip) ||
          @request.headers["X-Real-IP"]?
      end

      # Returns request headers.
      def headers : HTTP::Headers
        @request.headers
      end

      # Check if the current path matches.
      #
      # ```
      # ctx.current_page?("/users")               # => true if on /users
      # ctx.current_page?("/users", exact: false) # => true if path starts with /users
      # ```
      def current_page?(path : String, exact : Bool = true) : Bool
        if exact
          current_path == path
        else
          current_path.starts_with?(path)
        end
      end

      # Returns the Accept-Language header locale.
      def accept_language : String?
        if header = @request.headers["Accept-Language"]?
          # Parse Accept-Language header (e.g., "en-US,en;q=0.9,es;q=0.8")
          header.split(",").first?.try do |lang|
            lang.split(";").first.strip.split("-").first
          end
        end
      end

      # Convert context to a hash for template rendering.
      def to_template_vars : Hash(String, Crinja::Value)
        {
          "current_path"  => Crinja::Value.new(current_path),
          "current_url"   => Crinja::Value.new(current_url),
          "csrf_token"    => Crinja::Value.new(csrf_token),
          "csrf_tag"      => Crinja::Value.new(csrf_tag),
          "csrf_metatag"  => Crinja::Value.new(csrf_metatag),
          "flash"         => Crinja::Value.new(flash),
          "method"        => Crinja::Value.new(method),
          "secure"        => Crinja::Value.new(secure?),
          "ajax"          => Crinja::Value.new(ajax?),
          "referer"       => Crinja::Value.new(referer || ""),
          "client_ip"     => Crinja::Value.new(client_ip || ""),
          "accept_locale" => Crinja::Value.new(accept_language || "en"),
        }
      end

      private def extract_flash : Hash(String, String)
        flash_data = Hash(String, String).new

        if cookie = @cookies["_flash"]?
          begin
            # Decode flash from cookie (Base64 encoded JSON)
            decoded = Base64.decode_string(cookie.value)
            JSON.parse(decoded).as_h.each do |key, value|
              flash_data[key.to_s] = value.as_s
            end
          rescue ex
            # Invalid flash cookie, ignore
            Log.for("Azu::Helpers::Context").debug { "Failed to parse flash cookie: #{ex.message}" }
          end
        end

        flash_data
      end

      private def extract_session : Hash(String, String)
        session_data = Hash(String, String).new

        if cookie = @cookies["_session"]?
          begin
            # Decode session from cookie (Base64 encoded JSON)
            decoded = Base64.decode_string(cookie.value)
            JSON.parse(decoded).as_h.each do |key, value|
              session_data[key.to_s] = value.as_s
            end
          rescue ex
            # Invalid session cookie, ignore
            Log.for("Azu::Helpers::Context").debug { "Failed to parse session cookie: #{ex.message}" }
          end
        end

        session_data
      end
    end
  end
end
