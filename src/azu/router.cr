require "http/web_socket"

module Azu
  # Azu routing class that allows you to define routes for your application.
  #
  #
  # ```
  # ExampleApp.router do
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
  class Router
    alias Path = String
    RADIX     = Radix::Tree(Route).new
    RESOURCES = %w(connect delete get head options patch post put trace)

    record Route, namespace : Symbol, endpoint : HTTP::Handler, resource : String

    class DuplicateRoute < Exception
      def initialize(@namespace : Symbol, @method : Method, @path : Path, @endpoint : HTTP::Handler)
        super "namespace: #{namespace}, http_method: #{method}, path: #{path}, endpoint: #{endpoint}"
      end
    end

    # The Router::Builder class allows you to build routes more easily
    class Builder
      def initialize(@router : Router, @namespace : Symbol, @scope : String = "")
      end

      {% for method in RESOURCES %}
      def {{method.id}}(path : Path, endpoint : HTTP::Handler.class)
        @router.{{method.id}}("#{@scope}#{path}", endpoint, @namespace)
      end
      {% end %}
    end

    def routes(namespace : Symbol, scope : String = "")
      with Builder.new(self, namespace, scope) yield
    end

    def process(context : HTTP::Server::Context)
      result = RADIX.find path(context)
      raise Response::NotFound.new(context.request.path) unless result.found?
      context.request.path_params = result.params
      route = result.payload
      route.endpoint.call(context).to_s
    end

    {% for method in RESOURCES %}
    def {{method.id}}(path : Path, endpoint : HTTP::Handler.class, namespace : Symbol)
      method = Method.parse({{method}})
      add path, endpoint, namespace, method

      {% if method == "get" %}
      add path, endpoint, namespace, Method::Head

      {% if !%w(trace connect options head).includes? method %}
      add path, endpoint, namespace, Method::Options if method.add_options?
      {% end %}
      {% end %}
    end
    {% end %}

    # Registers the main route of the application
    #
    # ```
    # root :web, ExampleApp::HelloWorld
    # ```
    def root(endpoint : HTTP::Handler.class)
      RADIX.add "/get/", Route.new(namespace: :none, endpoint: endpoint.new, resource: "/get/")
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
      RADIX.add resource, Route.new(:websocket, handler, resource)
    end

    # Registers a route for a given path
    def add(path : Path, endpoint : HTTP::Handler.class, namespace : Symbol, method : Method)
      resource = "/#{method.to_s.downcase}#{path}"
      RADIX.add resource, Route.new(namespace: namespace, endpoint: endpoint.new, resource: resource)
    rescue ex : Radix::Tree::DuplicateError
      raise DuplicateRoute.new(namespace, method, path, endpoint.new)
    end

    private def path(context)
      upgraded = upgrade?(context)
      String.build do |str|
        str << "/"
        str << "ws" if upgraded
        str << context.request.method.downcase unless upgraded
        str << context.request.path.rstrip('/')
      end
    end

    private def upgrade?(context)
      return unless upgrade = context.request.headers["Upgrade"]?
      return unless upgrade.compare("websocket", case_insensitive: true) == 0
      context.request.headers.includes_word?("Connection", "Upgrade")
    end
  end
end
