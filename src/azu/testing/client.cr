require "base64"
require "random/secure"

module Azu
  module Testing
    class TooManyRedirects < Exception
    end

    # Drives an `Azu::App` in process: a request is built in memory and handed to the app's real handler
    # chain and router (`App#dispatcher`), with no socket. Each client has its own cookie jar and default
    # headers, so clients do not share state, and runs requests the way the server does: inside the app's
    # scope, an exception that escapes the chain becomes a 500.
    #
    # ```
    # client = Azu::Testing::Client.new(app)
    # response = client.post "/users", json: {name: "Ada"}
    # response.status_code # => 201
    # ```
    class Client
      MAX_REDIRECTS = 10
      # Verbs OpenAPI describes with query parameters instead of a body; the typed helpers follow it.
      NO_BODY = %w[GET DELETE HEAD OPTIONS TRACE]
      UNSAFE  = %w[POST PUT PATCH DELETE]
      ACCEPT  = {json: "application/json", html: "text/html", text: "text/plain", xml: "application/xml"}

      getter app : App
      getter cookies = CookieJar.new
      # Sent with every request, below the headers of the call.
      getter headers = HTTP::Headers.new
      getter clock : Clock::Fake?
      property? follow_redirects : Bool

      # *handlers* are the app's chain after its scope; a handler instance can serve one client only.
      def initialize(@app : App = App.default, handlers : Array(HTTP::Handler) = Client.default_handlers,
                     @clock : Clock::Fake? = nil, @follow_redirects : Bool = false)
        @handlers = handlers
        @dispatcher = @app.dispatcher(handlers)
        @csrf = nil.as({String, String}?)
      end

      def self.default_handlers : Array(HTTP::Handler)
        [Handler::RequestId.new, Handler::Rescuer.new] of HTTP::Handler
      end

      {% for verb in %w[get post put patch delete head options] %}
        def {{ verb.id }}(path : String, *, headers = nil, body : String? = nil, json = nil, form = nil, params = nil) : Response
          request({{ verb.upcase }}, path, headers: headers, body: body, json: json, form: form, params: params)
        end

        # Calls the route of *endpoint* with the fields of *request*, which must be the endpoint's own request
        # type. Path fields (`/users/:id`) fill the path; the others go to the query string for the verbs
        # OpenAPI gives no body (GET, DELETE, HEAD, OPTIONS) and to a JSON body, or a form with `form: true`.
        def {{ verb.id }}(endpoint : E.class, request : R, *, headers = nil, form : Bool = false) : Response forall E, R
          \{% begin %}
          \{% contract = E.ancestors.find { |a| a.name(generic_args: false) == "Azu::Endpoint" } %}
          \{% if contract && !(R <= contract.type_vars[0]) %}
            \{% raise "#{E} takes a #{contract.type_vars[0]}, not a #{R}" %}
          \{% end %}
          \{% end %}
          call_endpoint({{ verb.upcase }}, endpoint, request.to_www_form, request.to_json, headers, form)
        end

        # Calls the route of *endpoint* with path (and query) fields given as named arguments.
        def {{ verb.id }}(endpoint : E.class, *, headers = nil, form : Bool = false, **fields) : Response forall E
          call_endpoint({{ verb.upcase }}, endpoint, encode(fields), fields.to_json, headers, form)
        end
      {% end %}

      def request(method : String, path : String, *, headers = nil, body : String? = nil, json = nil, form = nil, params = nil) : Response
        merged = merge_headers(headers)
        payload = body
        if json
          payload = json.to_json
          merged["Content-Type"] = "application/json" unless merged.has_key?("Content-Type")
        elsif form
          payload = encode(form)
          merged["Content-Type"] = "application/x-www-form-urlencoded" unless merged.has_key?("Content-Type")
        end
        perform(method.upcase, params ? with_query(path, encode(params)) : path, merged, payload)
      end

      # Opens a WebSocket to the channel routed at *path*, sending the cookies of this client. Raises
      # `WebSocket::Rejected` when the handshake does not end in a 101.
      def connect(path : String, *, headers = nil) : WebSocket
        merged = merge_headers(headers)
        merged["Upgrade"] = "websocket"
        merged["Connection"] = "Upgrade"
        merged["Sec-WebSocket-Version"] = HTTP::WebSocket::Protocol::VERSION
        merged["Sec-WebSocket-Key"] = Base64.strict_encode(Random::Secure.random_bytes(16))

        context, io = context_for("GET", path, merged, nil)
        error = serve(context)
        handler = context.response.upgrade_handler
        raise WebSocket::Rejected.new(read(context, io, "GET", error)) unless handler && context.response.status.switching_protocols?

        client_io, server_io = Duplex.pair
        done = ::Channel(Nil).new
        spawn(name: "azu-testing-ws-server") { upgrade(handler, server_io, done) }
        WebSocket.new(client_io, done)
      end

      def accept(kind : Symbol) : self
        accept(ACCEPT[kind])
      end

      def accept(media_type : String) : self
        @headers["Accept"] = media_type
        self
      end

      # Every request carries this `X-Request-ID`, so logs and error documents can be matched to it.
      def request_id=(id : String) : String
        @headers["X-Request-ID"] = id
      end

      # Starts (or extends) a session of the in-memory session adapter and logs this client into it.
      def login_with(& : SessionAdapter::Values ->) : self
        sessions = Sessions.install(@app.config)
        values = @cookies[Sessions::COOKIE]?.try { |id| sessions[id] }
        unless values
          values = SessionAdapter::Values.new
          @cookies[Sessions::COOKIE] = sessions.start(values)
        end
        yield values
        self
      end

      # Fetches a token from the CSRF handler of the chain and sends it with every state-changing request.
      def with_csrf(csrf : Handler::CSRF? = nil) : self
        csrf ||= @handlers.compact_map(&.as?(Handler::CSRF)).first? || raise ArgumentError.new("no Azu::Handler::CSRF in this client's handlers")
        Sessions.install(@app.config) if @app.config.session_adapter.nil? && csrf.strategy.synchronizer_token? && csrf.token_store.is_a?(Handler::CSRF::SessionTokenStore)
        context, _ = context_for("GET", "/", merge_headers(nil), nil)
        token = scoped { csrf.token(context) }
        context.response.cookies.add_response_headers(context.response.headers)
        scoped { @cookies.absorb(context.response.headers) }
        @csrf = {csrf.header_name, token}
        self
      end

      # Moves the fake clock the client was given; cookies, caches and tokens age with it.
      def advance(span : Time::Span) : Nil
        (@clock || raise ArgumentError.new("give the client a clock: Client.new(app, clock: Azu::Clock::Fake.new)")).advance(span)
      end

      private def call_endpoint(verb : String, endpoint : E.class, form_fields : String, json : String, headers, form : Bool) : Response forall E
        fields = HTTP::Params.parse(form_fields)
        path = path_of(endpoint, fields)
        return request(verb, path, headers: headers, params: fields) if NO_BODY.includes?(verb)
        merged = merge_headers(headers)
        if form
          merged["Content-Type"] = "application/x-www-form-urlencoded"
          perform(verb, path, merged, fields.to_s)
        else
          merged["Content-Type"] = "application/json"
          perform(verb, path, merged, json)
        end
      end

      private def path_of(endpoint : Routable.class, fields : HTTP::Params) : String
        router = @app.router
        template = router.path_of(endpoint) || raise ArgumentError.new("#{endpoint} is not routed on this app")
        (router.mount_prefix + template).gsub(/\/[:*](\w+)/) do
          name = $1
          "/" + URI.encode_path_segment(fields.delete(name) || raise ArgumentError.new("path parameter #{name} of #{endpoint} is missing"))
        end
      end

      private def perform(method : String, target : String, headers : HTTP::Headers, body : String?, redirects : Int32 = 0) : Response
        response = exchange(method, target, headers, body)
        return response unless follow_redirects? && response.redirect?
        raise TooManyRedirects.new("more than #{MAX_REDIRECTS} redirects, last to #{response.location}") if redirects >= MAX_REDIRECTS

        location = URI.parse(target).resolve(response.location.to_s)
        next_target = location.request_target
        if response.status_code == 303 || (response.status_code.in?(301, 302) && !{"GET", "HEAD"}.includes?(method))
          perform("GET", next_target, without_body(headers), nil, redirects + 1)
        else
          perform(method, next_target, headers, body, redirects + 1)
        end
      end

      private def without_body(headers : HTTP::Headers) : HTTP::Headers
        headers.dup.tap { |copy| copy.delete("Content-Type"); copy.delete("Content-Length") }
      end

      private def exchange(method : String, target : String, headers : HTTP::Headers, body : String?) : Response
        context, io = context_for(method, target, headers, body)
        read(context, io, method, serve(context))
      end

      private def context_for(method : String, target : String, headers : HTTP::Headers, body : String?) : {HTTP::Server::Context, IO::Memory}
        headers = headers.dup
        headers["Host"] = "localhost" unless headers.has_key?("Host")
        scoped { cookie_header(target).try { |value| headers["Cookie"] = value unless headers.has_key?("Cookie") } }
        if (csrf = @csrf) && UNSAFE.includes?(method) && !headers.has_key?(csrf[0])
          headers[csrf[0]] = csrf[1]
        end
        request = HTTP::Request.new(method, target, headers, body)
        request.remote_address = Socket::IPAddress.new("127.0.0.1", 0)
        io = IO::Memory.new
        {HTTP::Server::Context.new(request, HTTP::Server::Response.new(io)), io}
      end

      private def cookie_header(target : String) : String?
        @cookies.header_for(target.partition('?')[0])
      end

      # Runs the chain the way `HTTP::Server` does: an exception that escapes answers 500 (returned for the Response).
      private def serve(context : HTTP::Server::Context) : Exception?
        scoped { @dispatcher.call(context) }
        nil
      rescue ex
        begin
          context.response.respond_with_status(:internal_server_error)
        rescue IO::Error
          # The headers had gone out already; the response stays as it was.
        end
        ex
      end

      private def read(context : HTTP::Server::Context, io : IO::Memory, method : String, error : Exception?) : Response
        context.response.close
        io.rewind
        parsed = HTTP::Client::Response.from_io(io, ignore_body: method == "HEAD")
        scoped { @cookies.absorb(parsed.headers) }
        Response.new(parsed.status, parsed.headers, parsed.body, error)
      end

      private def upgrade(handler : IO ->, io : IO, done : ::Channel(Nil)) : Nil
        handler.call(io)
      rescue IO::Error
      ensure
        io.close
        done.close
      end

      private def scoped(&)
        if clock = @clock
          Clock.use(clock) { in_app { yield } }
        else
          in_app { yield }
        end
      end

      private def in_app(&)
        Azu.with_app(@app) { Azu.with_config(@app.config) { yield } }
      end

      private def merge_headers(extra) : HTTP::Headers
        merged = @headers.dup
        extra.try(&.each { |name, value| merged[name.to_s] = value.is_a?(Array) ? value : value.to_s })
        merged
      end

      private def encode(fields : String | URI::Params) : String
        fields.to_s
      end

      private def encode(fields : Hash | NamedTuple) : String
        pairs = {} of String => String
        fields.each { |name, value| pairs[name.to_s] = value.to_s }
        HTTP::Params.encode(pairs)
      end

      private def with_query(path : String, query : String) : String
        query.empty? ? path : "#{path}#{path.includes?('?') ? '&' : '?'}#{query}"
      end
    end
  end
end
