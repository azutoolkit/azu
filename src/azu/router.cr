require "http/web_socket"
require "./method"
require "./routable"
require "./log_text"
require "./auth/principal"
require "./auth/access"

module Azu
  # Maps a method and a path to what serves it: an endpoint, a channel or another app. Endpoints declare their
  # routes with the verb macros (`get "/users/:id"`), which `App.default` registers; an app of your own takes
  # them through its route builder:
  #
  # ```
  # admin = Azu::App.new
  # app = Azu::App.new
  # app.routes do
  #   get "/", HomeEndpoint
  #   ws "/chat", ChatChannel
  #   scope "/api" do
  #     endpoint UsersEndpoint # the routes UsersEndpoint declared, below /api
  #   end
  #   mount admin, at: "/admin"
  # end
  # ```
  #
  # ### Path Normalization
  # - **Trailing slashes**: Trailing `/` characters are stripped when routes are registered and when incoming paths are matched (`/users/`, `/users//`, and `/users` all match `/users`; `//` matches `/`).
  # - **Doubled internal slashes**: Internal `/` characters are segment delimiters and are not collapsed (`/users//posts` has segments `["users", "", "posts"]` and does not match a static `/users/posts` route).
  class Router
    private LOG = Log.for("Azu::Router")

    alias Path = String
    RESOURCES           = %w(connect delete get head options patch post put trace)
    METHOD_OVERRIDE     = "_method"
    OVERRIDE_HEADER     = "X-HTTP-Method-Override"
    OVERRIDABLE_METHODS = %w(PUT PATCH DELETE)
    # The methods an `OPTIONS` or `405` answer lists in `Allow`, in this order; `OPTIONS` itself comes last on `OPTIONS`.
    ALLOW_ORDER = [Azu::Method::Get, Azu::Method::Head, Azu::Method::Post, Azu::Method::Put, Azu::Method::Patch,
                   Azu::Method::Delete, Azu::Method::Connect, Azu::Method::Trace, Azu::Method::Options]

    # Adapts a plain `HTTP::Handler` (such as `Authly::Handler`) into an `Azu::Routable` target.
    class HandlerAdapter
      include Routable

      getter handler : HTTP::Handler
      getter name : String

      def initialize(@handler : HTTP::Handler, @name : String = @handler.class.name)
      end

      def call(context : HTTP::Server::Context)
        @handler.call(context)
      end
    end

    # Heap-allocated box around a routable target so `Route` never stores a mixed struct+class `Routable` union field.
    abstract class Target
      abstract def call(context : HTTP::Server::Context)
      abstract def endpoint_class_name : String
      abstract def handler_name : String
      abstract def openapi_operation : OpenAPI::Operation?
      abstract def route_options : RouteOptions
      abstract def mount? : Bool
      abstract def mount : Mount?
      abstract def unwrap : Routable

      def self.wrap(endpoint) : Target
        if endpoint.is_a?(Target)
          endpoint
        elsif endpoint.is_a?(Routable)
          Of(typeof(endpoint)).new(endpoint)
        elsif endpoint.is_a?(HTTP::Handler)
          Of(HandlerAdapter).new(HandlerAdapter.new(endpoint))
        else
          inst = endpoint.new
          Of(typeof(inst)).new(inst)
        end
      end

      class Of(T) < Target
        getter endpoint : T

        def initialize(@endpoint : T)
        end

        def call(context : HTTP::Server::Context)
          # A struct is copied here: calling it where it is stored would keep the request's state (`@context`,
          # `@params`) in the one value every request shares, and a request that waits would answer with another's.
          endpoint = @endpoint
          endpoint.call(context)
        end

        def endpoint_class_name : String
          {% if T <= HandlerAdapter %}
            @endpoint.name
          {% else %}
            {{ T.name.stringify }}
          {% end %}
        end

        def handler_name : String
          {% if T <= Channel::Upgrader %}
            @endpoint.channel.name
          {% elsif T <= HandlerAdapter %}
            @endpoint.name
          {% else %}
            {{ T.name.stringify }}
          {% end %}
        end

        def openapi_operation : OpenAPI::Operation?
          @endpoint.openapi_operation
        end

        def route_options : RouteOptions
          @endpoint.route_options
        end

        def mount? : Bool
          {{ T <= Mount }}
        end

        def mount : Mount?
          {% if T <= Mount %}
            @endpoint
          {% else %}
            nil
          {% end %}
        end

        def unwrap : Routable
          @endpoint
        end

        def to_s(io : IO) : Nil
          @endpoint.to_s(io)
        end
      end
    end

    # Unified post-match router hook interface.
    # A hook may implement any subset of:
    # - `call(context, route)` — runs after route match (`404`/`405` passed, `path_params` extracted) and before the endpoint.
    # - `around(context, route, &)` — wraps endpoint execution.
    # - `after(context, route, error)` — runs in an `ensure` block after the endpoint finishes or raises `Response::Error`.
    module Hook
      def call(context : HTTP::Server::Context, route : Route) : Nil
      end

      def around(context : HTTP::Server::Context, route : Route, &) : Nil
        yield
      end

      def after(context : HTTP::Server::Context, route : Route, error : Response::Error?) : Nil
      end
    end

    alias AroundHook = Hook
    alias AfterHook = Hook

    private class BlockHook
      include Hook

      def initialize(
        @before : (HTTP::Server::Context, Route -> Nil)? = nil,
        @around : (HTTP::Server::Context, Route, Proc(Nil) -> Nil)? = nil,
        @after : (HTTP::Server::Context, Route, Response::Error? -> Nil)? = nil,
      )
      end

      def call(context : HTTP::Server::Context, route : Route) : Nil
        @before.try(&.call(context, route))
      end

      def around(context : HTTP::Server::Context, route : Route, &block : -> Nil) : Nil
        if cb = @around
          cb.call(context, route, -> { block.call; nil })
        else
          yield
        end
      end

      def after(context : HTTP::Server::Context, route : Route, error : Response::Error?) : Nil
        @after.try(&.call(context, route, error))
      end
    end

    # The routes `process` finds requests in, by method and path segment
    @tree = Tree(Route).new
    @frozen = Atomic(Bool).new(false)
    # The mounts of this router, whose routers `freeze` freezes too
    @mounts = [] of Mount
    # Routes registry for development tools and introspection
    private getter routes_registry : Array(Route)

    # Post-match router hooks
    getter before_hooks : Array(Hook) = [] of Hook
    getter around_hooks : Array(Hook) = [] of Hook
    getter after_hooks : Array(Hook) = [] of Hook

    # When `true`, a request whose path matches under another HTTP method answers `405 Method Not Allowed`
    # with an `Allow` header instead of `404 Not Found`. Defaults to `false` for backward compatibility.
    property? method_not_allowed : Bool = false

    # Custom responder for `405 Method Not Allowed`, receiving `(context, allowed_methods)`.
    property method_not_allowed_responder : Proc(HTTP::Server::Context, Array(String), Nil)? = nil

    # Custom responder for `404 Not Found`, receiving `context`.
    property not_found : Proc(HTTP::Server::Context, Nil)? = nil

    # Whether `GET` routes automatically answer `HEAD` requests with the body suppressed. Defaults to `true`.
    property? head_wrapping : Bool = true

    # Whether `POST` requests may override their method to `PUT`, `PATCH`, or `DELETE` via `X-HTTP-Method-Override`
    # or `_method`. Defaults to `true`.
    property? method_override : Bool = true

    def method_not_allowed=(responder : Proc(HTTP::Server::Context, Array(String), Nil))
      @method_not_allowed = true
      @method_not_allowed_responder = responder
    end

    def initialize
      @routes_registry = Array(Route).new
      @paths = Hash(String, String).new
    end

    # Registers a post-match hook that runs before the endpoint.
    def before_dispatch(hook : Hook) : self
      @before_hooks << hook
      self
    end

    # Registers a post-match block hook that runs before the endpoint.
    def before_dispatch(&block : HTTP::Server::Context, Route -> Nil) : self
      @before_hooks << BlockHook.new(before: block)
      self
    end

    # Registers an around-dispatch hook that wraps endpoint execution.
    def around_dispatch(hook : Hook) : self
      @around_hooks << hook
      self
    end

    # Registers an around-dispatch block hook.
    def around_dispatch(&block : HTTP::Server::Context, Route, Proc(Nil) -> Nil) : self
      @around_hooks << BlockHook.new(around: block)
      self
    end

    # Registers a post-dispatch hook that runs after the endpoint (or any `Response::Error` it raised).
    def after_dispatch(hook : Hook) : self
      @after_hooks << hook
      self
    end

    # Registers a post-dispatch block hook.
    def after_dispatch(&block : HTTP::Server::Context, Route, Response::Error? -> Nil) : self
      @after_hooks << BlockHook.new(after: block)
      self
    end

    # True when a `before_dispatch` hook of `type` is already registered on this router.
    def has_before_hook?(type : T.class) : Bool forall T
      @before_hooks.any?(T)
    end

    # True when an `around_dispatch` hook of `type` is already registered on this router.
    def has_around_hook?(type : T.class) : Bool forall T
      @around_hooks.any?(T)
    end

    # True when an `after_dispatch` hook of `type` is already registered on this router.
    def has_after_hook?(type : T.class) : Bool forall T
      @after_hooks.any?(T)
    end

    # Removes all dispatch hooks from this router.
    def clear_hooks : Nil
      @before_hooks.clear
      @around_hooks.clear
      @after_hooks.clear
    end

    # What a route points at is boxed in `Target` so a struct endpoint never lives in a `Routable` module field.
    struct Route
      getter target : Target
      getter resource : String
      getter method : Azu::Method
      getter options : RouteOptions
      getter? auto_head : Bool

      delegate requires, public?, enrolment_exempt?, csrf_exempt?, audit, audit_action,
        audit_critical?, summary, description, max_body_size, content_types, success_status, to: @options

      def initialize(
        endpoint : T,
        @resource : String,
        @method : Azu::Method,
        options : RouteOptions? = nil,
        *,
        scope_options : RouteOptions? = nil,
        @auto_head : Bool = false,
        **opts,
      ) forall T
        @target = Target.wrap(endpoint)
        call_opts = options || RouteOptions.new(**opts)
        ep_opts = @target.route_options
        @options = if scope = scope_options
                     scope.merge(ep_opts).merge(call_opts)
                   else
                     ep_opts.merge(call_opts)
                   end
      end

      # Returns the underlying `Routable` for backward compatibility.
      def endpoint : Routable
        @target.unwrap
      end

      # The path the route was declared with, without the method prefix of `resource`.
      def path : String
        path = method.web_socket? ? resource.lchop("/ws") : resource.lchop("/#{method.to_s.downcase}")
        path.empty? ? "/" : path
      end

      # Alias for `path` (e.g. `"/queues/:name"`).
      def pattern : String
        path
      end

      def mount? : Bool
        @target.mount?
      end

      # Effective access requirement for this route: `nil` when `public?`, else the route's own
      # `requires` (which includes any enclosing `scope` or endpoint requirement), else the verb default in `auth`.
      def effective_requirement(auth : Auth::Configuration) : Access::Requirement?
        return nil if public?
        requires || auth.default_access_for(@method)
      end
    end

    # Introspection entry returned by `Router#route_table`.
    struct RouteEntry
      getter method : Azu::Method
      getter pattern : String
      getter handler : String
      getter options : RouteOptions

      delegate public?, requires, enrolment_exempt?, csrf_exempt?, audit_action,
        audit_critical?, summary, description, max_body_size, content_types, success_status, to: @options

      def initialize(
        @method : Azu::Method,
        @pattern : String,
        @handler : String,
        options : RouteOptions? = nil,
        **opts,
      )
        @options = options || RouteOptions.new(**opts)
      end
    end

    class DuplicateRoute < Exception
    end

    # Raised by `add`, `root`, `ws`, `mount` and `register` once the router is frozen (see `freeze`).
    class Frozen < Exception
      def self.for(route : String) : self
        new("#{route}: a router takes no routes once its app is serving; declare them before App#start")
      end
    end

    # Takes no more routes. `App#start` calls it before it listens, so the tree and the registry are never changed
    # while requests read them; the routers of mounted apps are frozen with this one.
    def freeze : Nil
      return if @frozen.swap(true) # once: a mount cycle, or a router mounted on itself, ends here
      @mounts.each(&.child.router.freeze)
    end

    # True once `freeze` ran.
    def frozen? : Bool
      @frozen.get
    end

    {% for method in RESOURCES %}
      def {{method.id}}(
        path : Router::Path,
        handler : T,
        options : RouteOptions? = nil,
        *,
        scope_options : RouteOptions? = nil,
        **opts,
      ) forall T
        method = Azu::Method.parse({{method}})
        target = Target.wrap(handler)
        call_opts = options || RouteOptions.new(**opts)
        add path, target, method, call_opts, scope_options: scope_options

        {% if method == "get" %}
          add path, target, Azu::Method::Head, call_opts, scope_options: scope_options, auto_head: true
        {% end %}
      end
    {% end %}

    # Registers `handler` for the verb named by a string (one of `RESOURCES`), as the verb methods do.
    def register(
      verb : String,
      path : Router::Path,
      handler : T,
      options : RouteOptions? = nil,
      *,
      scope_options : RouteOptions? = nil,
      **opts,
    ) forall T
      call_opts = options || RouteOptions.new(**opts)
      {% begin %}
        case verb
        {% for method in RESOURCES %}
        when {{method}}
          {{method.id}}(path, handler, call_opts, scope_options: scope_options)
        {% end %}
        else raise ArgumentError.new("unknown HTTP verb #{verb.inspect}")
        end
      {% end %}
    end

    # Registers every route declared inside `type` on this router, optionally under `prefix`.
    def endpoint(
      type : T.class,
      options : RouteOptions? = nil,
      *,
      prefix : String = "",
      scope_options : RouteOptions? = nil,
      **opts,
    ) : Nil forall T
      raise ArgumentError.new("#{type} declares no routes: add get/post/... to its body") if type.routes.empty?
      call_opts = options || RouteOptions.new(**opts)
      type.routes.each do |(verb, path)|
        inline_opts = DeclaredEndpoints.route_options_of(type.name, verb, path)
        merged_call_opts = inline_opts ? inline_opts.merge(call_opts) : call_opts
        full_path = prefix.empty? ? path : (path == "/" ? prefix : prefix + path)
        register(verb, full_path, type.new, merged_call_opts, scope_options: scope_options)
      end
    end

    # Registers a pre-constructed endpoint `instance` (for example with constructor dependencies)
    # under every route declared inside its class/struct body.
    def endpoint(
      instance : T,
      options : RouteOptions? = nil,
      *,
      prefix : String = "",
      scope_options : RouteOptions? = nil,
      **opts,
    ) : Nil forall T
      routes = {{ T }}.routes
      raise ArgumentError.new("#{T} declares no routes: add get/post/... to its body") if routes.empty?
      call_opts = options || RouteOptions.new(**opts)
      routes.each do |(verb, path)|
        inline_opts = DeclaredEndpoints.route_options_of({{ T.name.stringify }}, verb, path)
        merged_call_opts = inline_opts ? inline_opts.merge(call_opts) : call_opts
        full_path = prefix.empty? ? path : (path == "/" ? prefix : prefix + path)
        register(verb, full_path, instance, merged_call_opts, scope_options: scope_options)
      end
    end

    # The path `endpoint` was last registered under, for building links to it. Nil when it is not routed here.
    def path_of(endpoint : Routable.class) : String?
      @paths[endpoint.name]?
    end

    # Where this router is mounted in another one; nil for a top-level router.
    property mounted_as : Mount?

    # What precedes every path of this router in the URLs clients see: the mount path, including
    # the ones of the routers it is mounted into.
    def mount_prefix : String
      @mounted_as.try(&.prefix) || ""
    end

    # Serves `child` below `prefix`: requests under it reach the child's router, with the prefix
    # removed, and run with the child's configuration. A router can be mounted once, because its
    # links carry the prefix it is mounted at.
    def mount(child : Configuration, at prefix : String) : Nil
      open! "mount at #{prefix}"
      prefix = prefix.rstrip('/')
      raise ArgumentError.new("a mount path must start with / and name a sub path, got #{prefix.inspect}") unless prefix.starts_with?('/')
      if existing = child.router.mounted_as
        raise ArgumentError.new("app is already mounted at #{existing.prefix}; build one app per mount")
      end

      mount = Mount.new(self, child, prefix)
      target = Target.wrap(mount)
      Azu::Method.each do |method|
        add prefix, target, method
        add "#{prefix}/*mount_path", target, method
      end
      child.router.mounted_as = mount
      @mounts << mount
    end

    @authly_mounted : Bool = false

    # Registers Authly's OAuth 2.0 and OpenID Connect provider endpoints on this router with
    # `public: true` and `csrf_exempt: true` on non-browser token/API endpoints so they integrate
    # seamlessly with Azu's authentication, CSRF guard, and route table.
    #
    # When `handler` is `nil` and `Authly` (`azutoolkit/authly`) is loaded, builds `Authly::Handler.new`.
    def mount_authly(
      handler : HTTP::Handler? = nil,
      *,
      prefix : String = "",
      scope_options : RouteOptions? = nil,
    ) : Nil
      return if @authly_mounted && prefix.empty?
      resolved = handler || default_authly_handler
      target = Target.wrap(HandlerAdapter.new(resolved, resolved.class.name))
      base = prefix.rstrip('/')

      browser_opts = RouteOptions.new(public: true)
      api_opts = RouteOptions.new(public: true, csrf_exempt: true)

      ["/oauth/authorize", "/device"].each do |route_path|
        get "#{base}#{route_path}", target, browser_opts, scope_options: scope_options
        post "#{base}#{route_path}", target, browser_opts, scope_options: scope_options
      end

      [
        "/oauth/token",
        "/oauth/par",
        "/oauth/device/code",
        "/oauth/introspect",
        "/introspect",
        "/oauth/revoke",
        "/revoke",
        "/oauth/register",
      ].each do |route_path|
        post "#{base}#{route_path}", target, api_opts, scope_options: scope_options
      end

      [
        "/oauth/userinfo",
        "/.well-known/openid-configuration",
        "/.well-known/oauth-authorization-server",
        "/.well-known/jwks.json",
      ].each do |route_path|
        get "#{base}#{route_path}", target, api_opts, scope_options: scope_options
      end

      @authly_mounted = true if prefix.empty?
    end

    private def default_authly_handler : HTTP::Handler
      {% if @top_level.has_constant?("Authly") %}
        Authly::Handler.new
      {% else %}
        raise ArgumentError.new("mount_authly without a handler requires `require \"authly\"` (azutoolkit/authly), or pass an HTTP::Handler")
      {% end %}
    end

    # Adds routes declared in the block, optionally below a path prefix.
    def routes(scope : String = "", &)
      with Builder.new(self, scope) yield
    end

    # Runs `HeadOutput.wrap` (when `head_wrapping?` is true) and `method_override` (when `method_override?` is true)
    # at most once per request.
    def prepare_request(context : HTTP::Server::Context) : Nil
      return if context.azu_request_prepared?
      context.azu_request_prepared = true
      HeadOutput.wrap(context) if @head_wrapping
      method_override(context) if @method_override
    end

    # Resolves and memoizes the route match on `context` so pre-routing checks (`public_route?`) and
    # `process` never walk the routing tree twice for the same router.
    def resolve(context : HTTP::Server::Context) : Tree::Match(Route)?
      prepare_request(context)
      return context.azu_resolved_match if context.azu_resolved_router_id == object_id

      match = route_method(context).try { |method| find_in_tree(method, context.request.path) }
      context.azu_resolved_match = match
      context.azu_resolved_router_id = object_id
      context.azu_match_resolved = true
      match
    end

    # True when the incoming request targets a route explicitly declared `public: true`
    # (or an `OPTIONS` preflight on a path that has a `public: true` route, or `HEAD` on a
    # `public: true` `GET` when `head_wrapping?` is enabled).
    def public_route?(context : HTTP::Server::Context) : Bool
      prepare_request(context)
      if match = resolve(context)
        route = match.payload
        if mount = route.target.mount
          return mount.public_route?(context)
        end
        return route.public?
      end

      if context.request.method == "OPTIONS" && !upgrade?(context)
        path = context.request.path
        ALLOW_ORDER.each do |method|
          next if method.options?
          if found = find_in_tree(method, path)
            route = found.payload
            if mount = route.target.mount
              return true if mount.public_route?(context)
            elsif route.public?
              return true
            end
          end
        end
      end

      false
    end

    def process(context : HTTP::Server::Context)
      match = resolve(context)
      return process_unmatched(context) if match.nil?

      # Nil for a route without parameters also forgets the `mount_path` of the mount that led here
      context.request.path_params = decode_params(match.params)
      route = match.payload

      # A mounted child app delegates to its own router, which will match its leaf route and run its own hooks.
      if route.mount?
        route.target.call(context)
        return ""
      end

      pattern = mount_prefix + route.path
      context.route_pattern = pattern
      context.matched_route = route
      RequestContext.current?.try(&.route_pattern = pattern)
      context.request.headers["X-Azu-Endpoint"] = route.target.endpoint_class_name

      dispatch_matched(context, route)
    end

    private def process_unmatched(context : HTTP::Server::Context)
      request = context.request
      if request.method == "OPTIONS" && !upgrade?(context)
        res = answer_options(context)
        finalize_direct_dispatch(context)
        return res
      end

      unless upgrade?(context)
        allowed, matched_other = allowed_methods_with_route(request.path)
        unless allowed.empty?
          if other_route = matched_other
            pattern = mount_prefix + other_route.path
            context.route_pattern = pattern
            RequestContext.current?.try(&.route_pattern = pattern)
          end
          if @method_not_allowed
            res = answer_method_not_allowed(context, allowed)
            finalize_direct_dispatch(context)
            return res
          end
        end
      end

      res = answer_not_found(context)
      finalize_direct_dispatch(context)
      res
    end

    private def dispatch_matched(context : HTTP::Server::Context, route : Route)
      if @before_hooks.empty? && @around_hooks.empty? && @after_hooks.empty?
        begin
          route.target.call(context)
        ensure
          finalize_direct_dispatch(context, matched: true)
        end
        return ""
      end

      caught_error : Response::Error? = nil
      halted = false
      begin
        @before_hooks.each do |hook|
          hook.call(context, route)
          if context.response.closed?
            halted = true
            break
          end
        end
        unless halted
          run_around_hooks(context, route, 0) do
            route.target.call(context)
          end
        end
      rescue ex : Response::Error
        caught_error = ex
        context.azu_last_error = ex
        LogText.log_client_error(LOG, ex.status_code) { LogText.client_error_line(context.request.method, context.request.path, ex.status_code, ex.title) }
        ex.to_s(context)
        halted = true
      ensure
        @after_hooks.each do |hook|
          hook.after(context, route, caught_error || context.azu_last_error)
        end
        finalize_direct_dispatch(context, matched: true)
      end
      halted ? nil : ""
    end

    private def finalize_direct_dispatch(context : HTTP::Server::Context, matched : Bool = false) : Nil
      unless matched || context.azu_unmatched_audited?
        context.azu_unmatched_audited = true
        duration = Time.instant - context.azu_started_at
        @after_hooks.each do |hook|
          if hook.is_a?(Auth::AuditHook)
            hook.emit_unmatched(context, duration, context.azu_last_error)
          end
        end
      end
      return if context.azu_in_app_scope?

      cfg = Azu.current_config
      cfg.report_response_for(context)
    end

    private def run_around_hooks(context : HTTP::Server::Context, route : Route, index : Int32, &block : -> Nil) : Nil
      if index < @around_hooks.size
        hook = @around_hooks[index]
        hook.around(context, route) do
          run_around_hooks(context, route, index + 1, &block)
        end
      else
        block.call
      end
    end

    private def find_in_tree(method : Azu::Method, path : String) : Tree::Match(Route)?
      found = @tree.find(method, path)
      return nil if found && found.payload.auto_head? && !@head_wrapping
      found
    end

    private def allowed_methods_with_route(path : String) : {Array(String), Route?}
      allowed = [] of String
      first_route : Route? = nil
      ALLOW_ORDER.each do |method|
        next if method.options?
        if found = find_in_tree(method, path)
          route = found.payload
          next if route.mount?
          first_route ||= route
          allowed << method.to_s.upcase
        end
      end
      if allowed.empty?
        if ws_found = @tree.find(Azu::Method::WebSocket, path)
          ws_route = ws_found.payload
          unless ws_route.mount?
            first_route ||= ws_route
            allowed << "GET"
          end
        end
      end
      if opt_found = @tree.find(Azu::Method::Options, path)
        opt_route = opt_found.payload
        unless opt_route.mount?
          first_route ||= opt_route
          allowed << "OPTIONS"
        end
      end
      {allowed, first_route}
    end

    # Percent-decodes the values of the path parameters: `/users/a%20b` reads `a b`, and `%2F` stays inside its
    # segment. A value with no `%` is left as it is, so a path without escapes allocates nothing here. The tree
    # keeps the raw text (it matches on the request path as sent); the endpoint sees the decoded one.
    private def decode_params(params : Hash(String, String)?) : Hash(String, String)?
      return params unless params
      params.each do |name, value|
        params[name] = URI.decode(value) if value.includes?('%')
      end
      params
    end

    # An `OPTIONS` that no `options` route takes: `204` with the methods the path routes in `Allow`, or `404` when it routes
    # none. With `Handler::CORS` in the chain a preflight never gets here; without it, the browser gets no
    # `Access-Control-*` header and refuses the cross-origin request, as it should.
    private def answer_options(context : HTTP::Server::Context) : String?
      path = context.request.path
      allowed = ALLOW_ORDER.reject(&.options?).select { |method| find_in_tree(method, path) }
      allowed << Azu::Method::Get if allowed.empty? && @tree.find(Azu::Method::WebSocket, path)
      return answer_not_found(context) if allowed.empty?

      response = context.response
      response.status = :no_content
      response.headers["Allow"] = (allowed.map(&.to_s.upcase) << "OPTIONS").join(", ")
      ""
    end

    private def answer_method_not_allowed(context : HTTP::Server::Context, allowed : Array(String)) : Nil
      context.response.status = :method_not_allowed
      context.response.headers["Allow"] = allowed.join(", ")
      if responder = @method_not_allowed_responder
        responder.call(context, allowed)
        return nil
      end
      ex = Response::MethodNotAllowed.new(context.request.method, context.request.path, allowed)
      context.azu_last_error = ex
      LogText.log_client_error(LOG, ex.status_code) { LogText.client_error_line(context.request.method, context.request.path, ex.status_code, ex.title) }
      ex.to_s(context)
    end

    private def answer_not_found(context : HTTP::Server::Context) : Nil
      if responder = @not_found
        context.response.status = :not_found
        responder.call(context)
        return nil
      end
      ex = not_found(context)
      context.azu_last_error = ex
      ex.to_s(context)
    end

    private def not_found(context)
      ex = Response::NotFound.new(context.request.path)
      LogText.log_client_error(LOG, ex.status_code) { LogText.client_error_line(context.request.method, context.request.path, ex.status_code, ex.title) }
      ex
    end

    # Registers the main route of the application
    def root(
      endpoint : T,
      options : RouteOptions? = nil,
      *,
      scope_options : RouteOptions? = nil,
      **opts,
    ) forall T
      open! "GET /"
      call_opts = options || RouteOptions.new(**opts)
      route = Route.new(endpoint, "/get/", Azu::Method::Get, call_opts, scope_options: scope_options)
      insert route, "/"
      @routes_registry << route
    end

    # Registers a websocket route
    def ws(
      path : String,
      channel : Channel.class,
      options : RouteOptions? = nil,
      *,
      scope_options : RouteOptions? = nil,
      **opts,
    )
      call_opts = options || RouteOptions.new(**opts)
      add path, Channel::Upgrader.new(channel), Azu::Method::WebSocket, call_opts, scope_options: scope_options
    end

    # Registers a route for a given path
    def add(
      path : Path,
      endpoint : T,
      method : Azu::Method = Azu::Method::Get,
      options : RouteOptions? = nil,
      *,
      scope_options : RouteOptions? = nil,
      auto_head : Bool = false,
      **opts,
    ) forall T
      open! "#{method.to_s.upcase} #{path}"
      resource = method.web_socket? ? "/ws#{path}" : "/#{method.to_s.downcase}#{path}"
      call_opts = options || RouteOptions.new(**opts)
      route = Route.new(endpoint, resource, method, call_opts, scope_options: scope_options, auto_head: auto_head)
      insert route, path
      @routes_registry << route
      @paths[route.target.endpoint_class_name] = route.path
    end

    private def open!(route : String) : Nil
      return unless @frozen.get
      raise Frozen.for(route)
    end

    # Into the tree, which refuses a path without its leading "/": no request could reach it, and a route meant to
    # shadow a broader one would silently not.
    private def insert(route : Route, path : Path) : Nil
      @tree.add route.method, route.path, route
    rescue Tree::DuplicateError
      raise DuplicateRoute.new("http_method: #{route.method}, path: #{path}, endpoint: #{route.target}")
    rescue ex : Tree::Error
      raise ArgumentError.new(ex.message)
    end

    # The tree slot a request names: its method when it is one of the verbs spelled exactly (methods are
    # case-sensitive), the WebSocket slot for an upgrade, which is a GET (RFC 6455). Nil, so 404, for any other.
    private def route_method(context) : Azu::Method?
      method = context.request.method
      return (Azu::Method::WebSocket if method == "GET") if upgrade?(context)
      verb(method)
    end

    # The method named by a verb spelled exactly, as a literal `case` and never `Azu::Method.parse?`, which ignores
    # case and underscores and would read `WEBSOCKET` as the WebSocket slot.
    private def verb(method : String) : Azu::Method?
      case method
      when "GET"     then Azu::Method::Get
      when "POST"    then Azu::Method::Post
      when "PUT"     then Azu::Method::Put
      when "PATCH"   then Azu::Method::Patch
      when "DELETE"  then Azu::Method::Delete
      when "HEAD"    then Azu::Method::Head
      when "OPTIONS" then Azu::Method::Options
      when "TRACE"   then Azu::Method::Trace
      when "CONNECT" then Azu::Method::Connect
      end
    end

    # HTML forms can only GET or POST, so a POST may ask to be handled as PUT, PATCH or DELETE
    # through a `_method` field (form body or query string) or the X-HTTP-Method-Override header.
    #
    # Only POST is overridable and only to those three verbs. A GET carrying `_method=delete`
    # would otherwise become a DELETE after the CSRF handler waved it through as a safe method.
    private def method_override(context)
      request = context.request
      return unless request.method == "POST"

      verb = (request.headers[OVERRIDE_HEADER]? || request.query_params[METHOD_OVERRIDE]? || form_override(request)).try(&.upcase)
      request.method = verb if verb && OVERRIDABLE_METHODS.includes?(verb)
    end

    # Reads `_method` from a urlencoded form body and leaves the body readable for the endpoint.
    private def form_override(request : HTTP::Request) : String?
      return unless request.content_type.sub_type == "x-www-form-urlencoded"
      return unless body = request.body

      content = Params::Body.read(body)
      request.body = IO::Memory.new(content)
      Params::Form.parse_encoded(content)[METHOD_OVERRIDE]?
    rescue ex : Params::TooLarge
      raise Response::PayloadTooLarge.new(ex.message.to_s)
    rescue MIME::Error # a Content-Type that does not parse is not a form; the endpoint answers it with 400
      nil
    end

    private def upgrade?(context)
      return unless upgrade = context.request.headers["Upgrade"]?
      return unless upgrade.compare("websocket", case_insensitive: true) == 0
      context.request.headers.includes_word?("Connection", "Upgrade")
    end

    # Does nothing, and is kept for the code that called it: the router has no path cache since it finds routes in
    # its segment tree, where a static route costs no allocation and a route with parameters only their values.
    def clear_path_cache : Nil
    end

    # The routes declared here, in declaration order. Mounted apps appear as the mount's own routes.
    def registered_routes : Array(Route)
      @routes_registry.dup
    end

    # Lists all leaf routes (including mounted child routers when `include_mounts` is true) with their
    # full path pattern, route record, and owning router.
    def leaf_routes(include_mounts : Bool = true, visited : Set(UInt64) = Set(UInt64).new) : Array(Tuple(String, Route, Router))
      result = [] of Tuple(String, Route, Router)
      return result unless visited.add?(object_id)

      @routes_registry.each do |route|
        next if route.mount?
        next if route.auto_head? && !@head_wrapping
        full_pattern = mount_prefix.empty? ? route.path : (route.path == "/" ? mount_prefix : mount_prefix + route.path)
        result << {full_pattern, route, self}
      end

      if include_mounts
        @mounts.each do |mount|
          result.concat(mount.child.router.leaf_routes(true, visited))
        end
      end

      result
    end

    # Returns the low-cardinality route table for metrics labels, OpenAPI inspection, and boot checks.
    def route_table(include_mounts : Bool = true) : Array(RouteEntry)
      leaf_routes(include_mounts).map do |(pattern, route, _owner)|
        RouteEntry.new(
          method: route.method,
          pattern: pattern,
          handler: route.target.handler_name,
          options: route.options
        )
      end
    end

    # Get route information for development tools
    # Build array of routes from the routes registry
    def route_info : Array(Hash(String, String))
      @routes_registry.map do |route|
        # Extract original path from resource by removing method prefix
        original_path = case route.method
                        when .web_socket?
                          route.resource.sub(/^\/ws/, "")
                        else
                          route.resource.sub(/^\/#{route.method.to_s.downcase}/, "")
                        end

        handler_name = route.target.handler_name

        {
          "method"      => route.method.to_s.upcase,
          "path"        => original_path.empty? ? "/" : original_path,
          "resource"    => route.resource,
          "handler"     => handler_name,
          "description" => route.summary || "#{route.method.to_s.upcase} route handler",
        }
      end
    end
  end
end

require "./router/tree"
require "./router/builder"
require "./router/mount"

class HTTP::Server::Context
  # Low-cardinality route pattern matched by `Azu::Router` (e.g. `"/queues/:name"`).
  # Nil on pre-routing `401` and unmatched `404`; populated on `2xx`, `403`, `405` (when the path
  # matched under another verb), `422`, `5xx`, and endpoint-raised `404`s.
  property route_pattern : String? = nil

  # The leaf `Azu::Router::Route` matched for this request, if any.
  property matched_route : Azu::Router::Route? = nil

  # :nodoc:
  property? azu_request_prepared : Bool = false

  # :nodoc:
  property? azu_match_resolved : Bool = false

  # :nodoc:
  property azu_resolved_router_id : UInt64 = 0_u64

  # :nodoc:
  property azu_resolved_match : Azu::Router::Tree::Match(Azu::Router::Route)? = nil

  # :nodoc:
  property azu_last_error : Azu::Response::Error? = nil

  # :nodoc:
  property azu_started_at : Time::Instant = Time.instant

  # :nodoc:
  property? azu_in_app_scope : Bool = false

  # :nodoc:
  property? azu_unmatched_audited : Bool = false
end
