require "http/web_socket"
require "radix"
require "./method"

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

    # Thread-safe path cache for frequently requested paths
    # Simplified cache implementation to avoid CI hanging issues
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
          # Simple cache without LRU eviction to avoid CI issues
          # In production, you might want to implement proper LRU
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
            size:     @cache.size,
            max_size: @max_size,
            hit_rate: calculate_hit_rate,
          }
        end
      end

      private def calculate_hit_rate : Float64
        # This is a simplified version - in production you'd track hits/misses
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
      precompute_method_cache
    end

    record Route,
      endpoint : HTTP::Handler,
      resource : String,
      method : Azu::Method

    class DuplicateRoute < Exception
    end

    # The Router::Builder class allows you to build routes more easily. Every path is
    # prefixed with the builder's scope, and endpoints can be given as instances or as
    # `Azu::Endpoint` classes.
    #
    # ```
    # routes "/api" do
    #   get "/hello/:name", HelloEndpoint
    #   get "/users/:id", ShowUser, as: :user
    #
    #   namespace "/v2" do
    #     post "/users", CreateUser # => POST /api/v2/users
    #   end
    #
    #   resources "/posts", index: ListPosts, show: ShowPost, create: CreatePost,
    #     update: UpdatePost, destroy: DeletePost
    # end
    # ```
    class Builder
      forward_missing_to @router

      def initialize(@router : Router, @scope : String = "")
      end

      {% for method in RESOURCES %}
        # Registers `{{method.id.upcase}} path` under this scope.
        def {{method.id}}(path : Router::Path, handler : HTTP::Handler)
          @router.{{method.id}}(scoped(path), handler)
        end

        # Registers `{{method.id.upcase}} path` under this scope for an endpoint class.
        # `as:` names the route (see `Azu::Routes`).
        def {{method.id}}(path : Router::Path, endpoint : T.class, as name : Symbol | String | Nil = nil) forall T
          endpoint.{{method.id}}(scoped(path), as: name, router: @router)
        end
      {% end %}

      # Registers the root route of this scope.
      def root(endpoint : HTTP::Handler)
        if @scope.empty?
          @router.root(endpoint)
        else
          @router.get(@scope, endpoint)
        end
      end

      # Groups routes under *prefix*.
      #
      # ```
      # namespace "/admin" do
      #   get "/stats", Stats # => GET /admin/stats
      # end
      # ```
      def namespace(prefix : String, &)
        with Builder.new(@router, scoped(prefix)) yield
      end

      # Alias of `namespace`.
      def scope(prefix : String, &)
        with Builder.new(@router, scoped(prefix)) yield
      end

      # Registers the conventional REST routes of a resource. Pass only the actions you have:
      #
      # | action    | route                      |
      # | --------- | -------------------------- |
      # | `index`   | `GET /posts`               |
      # | `new`     | `GET /posts/new`           |
      # | `create`  | `POST /posts`              |
      # | `show`    | `GET /posts/:id`           |
      # | `edit`    | `GET /posts/:id/edit`      |
      # | `update`  | `PATCH` and `PUT /posts/:id` |
      # | `destroy` | `DELETE /posts/:id`        |
      #
      # Named routes are `:posts`, `:new_post`, `:post` and `:edit_post`.
      def resources(path : Router::Path, index = nil, new new_form = nil, create = nil, show = nil, edit = nil, update = nil, destroy = nil) : Nil
        singular = Router.singularize(path.split('/').last)
        plural = path.split('/').last
        member = "#{path}/:id"

        mount(:get, path, index, plural) if index
        mount(:get, "#{path}/new", new_form, "new_#{singular}") if new_form
        mount(:post, path, create, nil) if create
        mount(:get, member, show, singular) if show
        mount(:get, "#{member}/edit", edit, "edit_#{singular}") if edit
        mount(:patch, member, update, nil) if update
        mount(:put, member, update, nil) if update
        mount(:delete, member, destroy, nil) if destroy
      end

      private def mount(verb : Symbol, path : String, endpoint, name : String?) : Nil
        case verb
        when :get    then get(path, endpoint, as: name)
        when :post   then post(path, endpoint, as: name)
        when :patch  then patch(path, endpoint, as: name)
        when :put    then put(path, endpoint, as: name)
        when :delete then delete(path, endpoint, as: name)
        end
      end

      private def scoped(path : String) : String
        return path if @scope.empty?
        joined = "#{@scope.rstrip('/')}/#{path.lstrip('/')}"
        joined.size > 1 ? joined.rstrip('/') : joined
      end
    end

    # "posts" => "post", "categories" => "category", "news" => "news"
    def self.singularize(word : String) : String
      if word.ends_with?("ies") && word.size > 3
        "#{word[0...-3]}y"
      elsif word.ends_with?("sses") || word.ends_with?("ches") || word.ends_with?("shes") || word.ends_with?("xes")
        word[0...-2]
      elsif word.ends_with?("s") && !word.ends_with?("ss") && word != "news"
        word[0...-1]
      else
        word
      end
    end

    {% for method in RESOURCES %}
      def {{method.id}}(path : Router::Path, handler : HTTP::Handler)
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

    # Adds scoped routes
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
    def root(endpoint : HTTP::Handler)
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
      handler = HTTP::WebSocketHandler.new do |socket, context|
        channel.new(socket).call(context)
      end
      resource = "/ws#{path}"
      route = Route.new(handler, resource, Azu::Method::WebSocket)
      @routes_registry << route
      @radix.add resource, route
    end

    # Registers a route for a given path
    #
    # ```
    # add path: '/proc', endpoint: ->(env) { [200, {}, ['Hello from Hanami!']] }, method: Azu::Method::Get
    # add path: '/endpoint',   endpoint: Handler.new, method: Azu::Method::Get
    # ```
    def add(path : Path, endpoint : HTTP::Handler, method : Azu::Method = Azu::Method::Get)
      resource = "/#{method.to_s.downcase}#{path}"
      route = Route.new(endpoint, resource, method)
      @routes_registry << route
      @radix.add resource, route
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
        handler_name = route.endpoint.class.name

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
