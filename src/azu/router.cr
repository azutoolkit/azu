require "http/web_socket"
require "radix"
require "./method"
require "./routable"

module Azu
  # Defines an Azu Router
  #
  # The router provides a set of methods for mapping routes that dispatch to
  # specific endpoints or handers. For example
  #
  # ```
  # MyAppWeb.router do
  #   root :web, ExampleApp::HelloWorld
  #   ws "/hi", ExampleApp::ExampleChannel
  #
  #   routes :web, "/test" do
  #     get "/hello/", ExampleApp::HelloWorld
  #     get "/hello/:name", ExampleApp::HtmlEndpoint
  #     get "/hello/json", ExampleApp::JsonEndpoint
  #   end
  # end
  # ```
  #
  # You can use most common HTTP verbs: GET, POST, PUT, PATCH, DELETE, TRACE
  # and OPTIONS.
  #
  # ```
  # endpoint = ->(env) { [200, {}, ['Hello from Hanami!']] }
  #
  # get     '/hello', to: endpoint
  # post    '/hello', to: endpoint
  # put     '/hello', to: endpoint
  # patch   '/hello', to: endpoint
  # delete  '/hello', to: endpoint
  # trace   '/hello', to: endpoint
  # options '/hello', to: endpoint
  # ```
  class Router
    alias Path = String
    RESOURCES           = %w(connect delete get head options patch post put trace)
    METHOD_OVERRIDE     = "_method"
    OVERRIDE_HEADER     = "X-HTTP-Method-Override"
    OVERRIDABLE_METHODS = %w(PUT PATCH DELETE)

    # Thread-safe path cache for frequently requested paths. Stops adding entries at `max_size`.
    private struct PathCache
      DEFAULT_MAX_SIZE = 1000

      def initialize(@max_size : Int32 = DEFAULT_MAX_SIZE)
        @cache = Hash(String, String).new
        @mutex = Mutex.new
      end

      def get(key : String) : String?
        @mutex.synchronize do
          @cache[key]?
        end
      end

      def set(key : String, value : String) : Nil
        @mutex.synchronize do
          # Once full, new paths are simply not cached; there is no eviction
          if @cache.size < @max_size
            @cache[key] = value
          end
        end
      end

      def clear : Nil
        @mutex.synchronize do
          @cache.clear
        end
      end

      # Get cache statistics (useful for monitoring)
      def stats
        @mutex.synchronize do
          {
            size:         @cache.size,
            max_size:     @max_size,
            fill_percent: fill_percent,
          }
        end
      end

      # How full the cache is, not a hit rate: nothing counts hits or misses.
      private def fill_percent : Float64
        @cache.size.to_f / @max_size.to_f * 100.0
      end
    end

    getter radix : Radix::Tree(Route)
    getter path_cache : PathCache
    private getter method_cache : Hash(String, String)
    # Routes registry for development tools and introspection
    private getter routes_registry : Array(Route)

    def initialize
      @radix = Radix::Tree(Route).new
      @path_cache = PathCache.new
      @method_cache = Hash(String, String).new
      @routes_registry = Array(Route).new
      @paths = Hash(String, String).new
      precompute_method_cache
    end

    # What a route points at is `Routable`: an endpoint (class or struct) or any `HTTP::Handler`.
    # A struct that needs to be routed to should include `Azu::Routable`, not `HTTP::Handler`:
    # the handler's `next` link makes a struct contain itself and the compiler rejects it.
    record Route,
      endpoint : Routable,
      resource : String,
      method : Azu::Method do
      # The path the route was declared with, without the method prefix the radix tree is keyed by.
      def path : String
        path = method.web_socket? ? resource.lchop("/ws") : resource.lchop("/#{method.to_s.downcase}")
        path.empty? ? "/" : path
      end
    end

    class DuplicateRoute < Exception
    end

    {% for method in RESOURCES %}
      def {{method.id}}(path : Router::Path, handler : Routable)
        method = Azu::Method.parse({{method}})
        add path, handler, method

        {% if method == "get" %}
          add path, handler, Azu::Method::Head

          {% if !%w(trace connect options head).includes? method %}
          add path, handler, Azu::Method::Options if method.add_options?
          {% end %}
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
    end

    # Adds routes declared in the block, optionally below a path prefix.
    def routes(scope : String = "", &)
      with Builder.new(self, scope) yield
    end

    def process(context : HTTP::Server::Context)
      method_override(context)
      result = @radix.find path(context)
      return not_found(context).to_s(context) unless result.found?
      context.request.path_params = result.params
      route = result.payload

      # Store endpoint information in context for logging
      endpoint_class_name = route.endpoint.class.name
      context.request.headers["X-Azu-Endpoint"] = endpoint_class_name

      route.endpoint.call(context).to_s
    end

    private def not_found(context)
      ex = Response::NotFound.new(context.request.path)
      Log.error(exception: ex) { "Router: Error Processing Request ".colorize(:yellow) }
      ex
    end

    # Registers the main route of the application
    #
    # ```
    # root :web, ExampleApp::HelloWorld
    # ```
    def root(endpoint : Routable)
      route = Route.new(endpoint: endpoint, resource: "/get/", method: Azu::Method::Get)
      @routes_registry << route
      @radix.add "/get/", route
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
      resource = method.web_socket? ? "/ws#{path}" : "/#{method.to_s.downcase}#{path}"
      route = Route.new(endpoint, resource, method)
      @radix.add resource, route
      @routes_registry << route
      @paths[endpoint.class.name] = route.path
    rescue ex : Radix::Tree::DuplicateError
      raise DuplicateRoute.new("http_method: #{method}, path: #{path}, endpoint: #{endpoint}")
    end

    # Pre-compute method cache at startup to avoid repeated downcasing
    private def precompute_method_cache : Nil
      RESOURCES.each do |method|
        @method_cache[method.upcase] = method.downcase
      end

      # Add common HTTP methods that might not be in RESOURCES
      %w(HEAD OPTIONS).each do |method|
        @method_cache[method] = method.downcase
      end
    end

    # Optimized path building with caching and efficient string operations
    private def path(context) : String
      request = context.request
      method_str = request.method
      path_str = request.path
      upgraded = upgrade?(context)

      # Create cache key for this specific request combination
      cache_key = if upgraded
                    "ws:#{path_str}"
                  else
                    "#{method_str}:#{path_str}"
                  end

      # Check cache first
      if cached_path = @path_cache.get(cache_key)
        return cached_path
      end

      # Build path efficiently using pre-allocated capacity
      built_path = if upgraded
                     # WebSocket path: "/ws" + normalized_path
                     normalized_path = path_str.rstrip('/')
                     String.build(capacity: 4 + normalized_path.bytesize) do |str|
                       str << "/ws"
                       str << normalized_path
                     end
                   else
                     # HTTP path: "/" + method + normalized_path
                     normalized_path = path_str.rstrip('/')
                     method_lower = @method_cache[method_str]? || method_str.downcase
                     String.build(capacity: 1 + method_lower.bytesize + normalized_path.bytesize) do |str|
                       str << "/"
                       str << method_lower
                       str << normalized_path
                     end
                   end

      # Cache the result for future requests
      @path_cache.set(cache_key, built_path)
      built_path
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
      HTTP::Params.parse(content)[METHOD_OVERRIDE]?
    rescue ex : Params::TooLarge
      raise Response::PayloadTooLarge.new(ex.message.to_s)
    end

    private def upgrade?(context)
      return unless upgrade = context.request.headers["Upgrade"]?
      return unless upgrade.compare("websocket", case_insensitive: true) == 0
      context.request.headers.includes_word?("Connection", "Upgrade")
    end

    # Clear path cache (useful for testing or memory management)
    def clear_path_cache : Nil
      @path_cache.clear
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
