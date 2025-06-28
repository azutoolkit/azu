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
    RESOURCES       = %w(connect delete get head options patch post put trace)
    METHOD_OVERRIDE = "_method"

    # Path cache for frequently requested paths
    # LRU cache with configurable maximum size
    private struct PathCache
      DEFAULT_MAX_SIZE = 1000

      def initialize(@max_size : Int32 = DEFAULT_MAX_SIZE)
        @cache = Hash(String, String).new
        @access_order = Array(String).new
      end

      def get(key : String) : String?
        if cached_path = @cache[key]?
          # Move to end (most recently used)
          @access_order.delete(key)
          @access_order << key
          cached_path
        end
      end

      def set(key : String, value : String) : Nil
        # Remove if already exists to update position
        if @cache.has_key?(key)
          @access_order.delete(key)
        elsif @cache.size >= @max_size
          # Remove least recently used
          if oldest = @access_order.shift?
            @cache.delete(oldest)
          end
        end

        @cache[key] = value
        @access_order << key
      end

      def clear : Nil
        @cache.clear
        @access_order.clear
      end
    end

    getter radix : Radix::Tree(Route)
    private getter path_cache : PathCache
    private getter method_cache : Hash(String, String)

    def initialize
      @radix = Radix::Tree(Route).new
      @path_cache = PathCache.new
      @method_cache = Hash(String, String).new
      precompute_method_cache
    end

    record Route,
      endpoint : HTTP::Handler,
      resource : String,
      method : Azu::Method

    class DuplicateRoute < Exception
    end

    # The Router::Builder class allows you to build routes more easily
    #
    # ```
    # routes :web, "/test" do
    #   get "/hello/", ExampleApp::HelloWorld
    #   get "/hello/:name", ExampleApp::HtmlEndpoint
    #   get "/hello/json", ExampleApp::JsonEndpoint
    # end
    # ```
    class Builder
      forward_missing_to @router

      def initialize(@router : Router, @scope : String = "")
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
      @radix.add "/get/", Route.new(endpoint: endpoint, resource: "/get/", method: Azu::Method::Get)
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
      @radix.add resource, Route.new(handler, resource, Azu::Method::WebSocket)
    end

    # Registers a route for a given path
    #
    # ```
    # add path: '/proc', endpoint: ->(env) { [200, {}, ['Hello from Hanami!']] }, method: Azu::Method::Get
    # add path: '/endpoint',   endpoint: Handler.new, method: Azu::Method::Get
    # ```
    def add(path : Path, endpoint : HTTP::Handler, method : Azu::Method = Azu::Method::Get)
      resource = "/#{method.to_s.downcase}#{path}"
      @radix.add resource, Route.new(endpoint, resource, method)
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

    private def method_override(context)
      if value = context.request.query_params[METHOD_OVERRIDE]?
        context.request.method = value.upcase
      end
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
  end
end
