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
      # Parsed when first read, like the other values: a render pays only for what its template reads.
      getter params : HTTP::Params { @request.query_params }
      getter cookies : HTTP::Cookies { HTTP::Cookies.from_client_headers(@request.headers) }

      # :nodoc:
      # The variables `view` gives a template rendered with a request: name => how to compute it for a context.
      TEMPLATE_VARS = {
        "current_path"  => ->(c : TemplateContext) { Crinja::Value.new(c.current_path) },
        "current_url"   => ->(c : TemplateContext) { Crinja::Value.new(c.current_url) },
        "csrf_token"    => ->(c : TemplateContext) { Crinja::Value.new(c.csrf_token) },
        "csrf_tag"      => ->(c : TemplateContext) { Crinja::Value.new(Crinja::SafeString.new(c.csrf_tag)) },
        "csrf_metatag"  => ->(c : TemplateContext) { Crinja::Value.new(Crinja::SafeString.new(c.csrf_metatag)) },
        "flash"         => ->(c : TemplateContext) { Crinja::Value.new(c.flash) },
        "method"        => ->(c : TemplateContext) { Crinja::Value.new(c.method) },
        "secure"        => ->(c : TemplateContext) { Crinja::Value.new(c.secure?) },
        "ajax"          => ->(c : TemplateContext) { Crinja::Value.new(c.ajax?) },
        "referer"       => ->(c : TemplateContext) { Crinja::Value.new(c.referer || "") },
        "client_ip"     => ->(c : TemplateContext) { Crinja::Value.new(c.client_ip || "") },
        "accept_locale" => ->(c : TemplateContext) { Crinja::Value.new(c.accept_language || "en") },
      }

      # :nodoc:
      VARIABLES = TEMPLATE_VARS.keys

      @flash : Hash(String, String)?
      @session : Hash(String, String)?
      @csrf_token : String?

      def initialize(@context : HTTP::Server::Context)
        @request = @context.request
        @response = @context.response
      end

      # The CSRF variables: there only once the app has built a CSRF handler (`Handler::CSRF.in_use?`), so the pages
      # of an app without CSRF protection set no token cookie and need no `CSRF_SECRET`.
      CSRF_VARIABLES = {"csrf_token", "csrf_tag", "csrf_metatag"}

      # :nodoc:
      # The context of one render. With a CSRF handler the token is issued now, so the token cookie is set on every
      # render whether or not the template prints a token; everything else waits until the template reads it
      # (`template_var`).
      def self.for_render(context : HTTP::Server::Context) : TemplateContext
        new(context).tap { |vars| vars.csrf_token if Handler::CSRF.in_use? }
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

      # The scheme the request was made with: `https` when this app terminates TLS, else what a trusted proxy says in
      # `X-Forwarded-Proto` (`config.trusted_proxies`), else `http`.
      def scheme : String
        return "https" if Azu.current_config.tls?
        forwarded("X-Forwarded-Proto").try(&.downcase) || "http"
      end

      # The host the request was made to: `X-Forwarded-Host` from a trusted proxy, else the `Host` header.
      def host : String
        forwarded("X-Forwarded-Host") || @request.headers["Host"]? || "localhost"
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

      # Returns flash messages from the session adapter (`Azu.session_adapter`), empty without one.
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
      # Session values come from `Azu.session_adapter` and are empty without one. A cookie the
      # client can write is never read as session data.
      def session : Hash(String, String)
        @session ||= extract_session
      end

      # Returns CSRF token for the current request: the one already issued for its response (the CSRF cookie, or the
      # session's with `SessionTokenStore`; an earlier `view` of the same request reuses it), so `csrf_tag` and
      # `csrf_metatag` carry the same token.
      #
      # ```jinja
      # <input type="hidden" name="_csrf" value="{{ csrf_token }}" />
      # ```
      def csrf_token : String
        @csrf_token ||= Handler::CSRF.token(@context)
      end

      # Returns CSRF hidden input tag.
      #
      # ```jinja
      # {{ csrf_tag }}
      # ```
      def csrf_tag : String
        Handler::CSRF.default.tag(csrf_token)
      end

      # Returns CSRF meta tag for AJAX requests.
      #
      # ```jinja
      # {{ csrf_metatag }}
      # ```
      def csrf_metatag : String
        Handler::CSRF.default.metatag(csrf_token)
      end

      # Returns the referer URL.
      def referer : String?
        @request.headers["Referer"]?
      end

      # Returns the user agent string.
      def user_agent : String?
        @request.headers["User-Agent"]?
      end

      # The client's address: the peer of the connection, or, when that peer is a trusted proxy
      # (`config.trusted_proxies`), the client its `X-Forwarded-For` names (the right-most address that is not a
      # trusted proxy, as `Handler::Throttle` reads it). Nil without an IP peer, or when the proxy's header names nobody.
      def client_ip : String?
        peer = @request.remote_address.as?(Socket::IPAddress) || return
        parsed = Handler::ClientAddress.parse(peer.address) || return peer.address
        trusted = Azu.current_config.trusted_proxy_networks
        client = Handler::ClientAddress.client(parsed, @request.headers.get?("X-Forwarded-For"), trusted) || return
        Handler::ClientAddress.to_s(client)
      end

      # The first value of *header*, when the connection's peer is a trusted proxy; nil otherwise.
      private def forwarded(header : String) : String?
        Handler::ClientAddress.forwarded(@request, header)
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

      # Convert context to a hash for template rendering: every variable `view` gives a template.
      def to_template_vars : Hash(String, Crinja::Value)
        vars = Handler::CSRF.in_use? ? TEMPLATE_VARS : TEMPLATE_VARS.reject { |name, _| CSRF_VARIABLES.includes?(name) }
        vars.transform_values(&.call(self))
      end

      # :nodoc:
      # The template variable `name` for this request, nil for a name that is not one of `TEMPLATE_VARS`.
      def template_var(name : String) : Crinja::Value?
        return if !Handler::CSRF.in_use? && CSRF_VARIABLES.includes?(name)
        TEMPLATE_VARS[name]?.try &.call(self)
      end

      private def extract_flash : Hash(String, String)
        Azu.session_adapter.try(&.flash(@context)) || Hash(String, String).new
      end

      private def extract_session : Hash(String, String)
        Azu.session_adapter.try(&.session(@context)) || Hash(String, String).new
      end
    end
  end
end
