require "http/web_socket"
require "./method"
require "./routable"
require "./log_text"

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
  class Router
    private LOG = Log.for("Azu::Router")

    alias Path = String
    RESOURCES           = %w(connect delete get head options patch post put trace)
    METHOD_OVERRIDE     = "_method"
    OVERRIDE_HEADER     = "X-HTTP-Method-Override"
    OVERRIDABLE_METHODS = %w(PUT PATCH DELETE)
    # The methods an `OPTIONS` answer lists in `Allow`, in this order; `OPTIONS` itself comes last.
    ALLOW_ORDER = [Azu::Method::Get, Azu::Method::Head, Azu::Method::Post, Azu::Method::Put, Azu::Method::Patch,
                   Azu::Method::Delete, Azu::Method::Connect, Azu::Method::Trace]

    # The routes `process` finds requests in, by method and path segment
    @tree = Tree(Route).new
    @frozen = Atomic(Bool).new(false)
    # The mounts of this router, whose routers `freeze` freezes too
    @mounts = [] of Mount
    # Routes registry for development tools and introspection
    private getter routes_registry : Array(Route)

    def initialize
      @routes_registry = Array(Route).new
      @paths = Hash(String, String).new
    end

    # What a route points at is `Routable`: an endpoint (class or struct) or any `HTTP::Handler`.
    # A struct that needs to be routed to should include `Azu::Routable`, not `HTTP::Handler`:
    # the handler's `next` link makes a struct contain itself and the compiler rejects it.
    record Route,
      endpoint : Routable,
      resource : String,
      method : Azu::Method do
      # The path the route was declared with, without the method prefix of `resource`.
      def path : String
        path = method.web_socket? ? resource.lchop("/ws") : resource.lchop("/#{method.to_s.downcase}")
        path.empty? ? "/" : path
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
      def {{method.id}}(path : Router::Path, handler : Routable)
        method = Azu::Method.parse({{method}})
        add path, handler, method

        {% if method == "get" %}
          add path, handler, Azu::Method::Head
        {% end %}
      end
    {% end %}

    # Registers `handler` for the verb named by a string (one of `RESOURCES`), as the verb methods do.
    def register(verb : String, path : Router::Path, handler : Routable)
      {% begin %}
        case verb
        {% for method in RESOURCES %}
        when {{method}} then {{method.id}}(path, handler)
        {% end %}
        else raise ArgumentError.new("unknown HTTP verb #{verb.inspect}")
        end
      {% end %}
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
      Azu::Method.each do |method|
        add prefix, mount, method
        add "#{prefix}/*mount_path", mount, method
      end
      child.router.mounted_as = mount
      @mounts << mount
    end

    # Adds routes declared in the block, optionally below a path prefix.
    def routes(scope : String = "", &)
      with Builder.new(self, scope) yield
    end

    def process(context : HTTP::Server::Context)
      HeadOutput.wrap(context)
      method_override(context)
      request = context.request
      match = route_method(context).try { |method| @tree.find(method, request.path) }
      return answer_options(context) if match.nil? && request.method == "OPTIONS" && !upgrade?(context)
      return not_found(context).to_s(context) unless match
      # Nil for a route without parameters also forgets the `mount_path` of the mount that led here
      request.path_params = match.params
      route = match.payload

      # Store endpoint information in context for logging
      endpoint_class_name = route.endpoint.class.name
      context.request.headers["X-Azu-Endpoint"] = endpoint_class_name

      route.endpoint.call(context)
      ""
    end

    # An `OPTIONS` that no `options` route takes: `204` with the methods the path routes in `Allow`, or `404` when it routes
    # none. With `Handler::CORS` in the chain a preflight never gets here; without it, the browser gets no
    # `Access-Control-*` header and refuses the cross-origin request, as it should.
    private def answer_options(context : HTTP::Server::Context) : String?
      path = context.request.path
      allowed = ALLOW_ORDER.select { |method| @tree.find(method, path) }
      allowed << Azu::Method::Get if allowed.empty? && @tree.find(Azu::Method::WebSocket, path)
      return not_found(context).to_s(context) if allowed.empty?

      response = context.response
      response.status = :no_content
      response.headers["Allow"] = (allowed.map(&.to_s.upcase) << "OPTIONS").join(", ")
      ""
    end

    private def not_found(context)
      ex = Response::NotFound.new(context.request.path)
      LogText.log_client_error(LOG, ex.status_code) { LogText.client_error_line(context.request.method, context.request.path, ex.status_code, ex.title) }
      ex
    end

    # Registers the main route of the application
    #
    # ```
    # root :web, ExampleApp::HelloWorld
    # ```
    def root(endpoint : Routable)
      open! "GET /"
      route = Route.new(endpoint: endpoint, resource: "/get/", method: Azu::Method::Get)
      insert route, "/"
      @routes_registry << route
    end

    # Registers a websocket route
    #
    # ```
    # ws "/hi", ExampleApp::ExampleChannel
    # ```
    def ws(path : String, channel : Channel.class)
      add path, Channel::Upgrader.new(channel), Azu::Method::WebSocket
    end

    # Registers a route for a given path
    #
    # ```
    # add path: '/proc', endpoint: ->(env) { [200, {}, ['Hello from Hanami!']] }, method: Azu::Method::Get
    # add path: '/endpoint',   endpoint: Handler.new, method: Azu::Method::Get
    # ```
    def add(path : Path, endpoint : Routable, method : Azu::Method = Azu::Method::Get)
      open! "#{method.to_s.upcase} #{path}"
      resource = method.web_socket? ? "/ws#{path}" : "/#{method.to_s.downcase}#{path}"
      route = Route.new(endpoint, resource, method)
      insert route, path
      @routes_registry << route
      @paths[endpoint.class.name] = route.path
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
      raise DuplicateRoute.new("http_method: #{route.method}, path: #{path}, endpoint: #{route.endpoint}")
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

        # Get handler class name
        endpoint = route.endpoint
        handler_name = endpoint.is_a?(Channel::Upgrader) ? endpoint.channel.name : endpoint.class.name

        {
          "method"      => route.method.to_s.upcase,
          "path"        => original_path.empty? ? "/" : original_path,
          "resource"    => route.resource,
          "handler"     => handler_name,
          "description" => "#{route.method.to_s.upcase} route handler",
        }
      end
    end
  end
end

require "./router/builder"
require "./router/mount"
