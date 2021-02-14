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

    record Route,
      endpoint : HTTP::Handler,
      resource : String, method : Method,
      accept : String = "", content_type : String = "" do
      def valid?(context)
        request_accecpt = context.request.headers["Accept"]?
        request_content = context.request.headers["Content-Type"]?
      end
    end

    class DuplicateRoute < Exception
      def initialize(@method : Method, @path : Path, @endpoint : HTTP::Handler)
        super "http_method: #{method}, path: #{path}, endpoint: #{endpoint}"
      end
    end

    # The Router::Builder class allows you to build routes more easily
    class Builder
      forward_missing_to @router

      def initialize(@router : Router, @scope : String = "")
      end
    end

    def routes(scope : String = "")
      with Builder.new(self, scope) yield
    end

    def process(context : HTTP::Server::Context)
      result = RADIX.find path(context)
      return not_found(context).to_s(context) unless result.found?
      context.request.path_params = result.params
      route = result.payload
      route.valid?(context)
      context.response.content_type = route.content_type
      route.endpoint.call(context).to_s
    end

    private def not_found(context)
      ex = Response::NotFound.new(context.request.path)
      context.response.status_code = ex.status_code
      ContentNegotiator.content_type context
      Log.error(exception: ex) { "Router: Error Processing Request ".colorize(:yellow) }
      ex
    end

    # Registers the main route of the application
    #
    # ```
    # root :web, ExampleApp::HelloWorld
    # ```
    def root(endpoint : HTTP::Handler.class)
      RADIX.add "/get/", Route.new(endpoint: endpoint.new, resource: "/get/", method: Method::Get)
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
      RADIX.add resource, Route.new(handler, resource, Method::WebSocket)
    end

    # Registers a route for a given path
    def add(
      path : Path,
      endpoint : HTTP::Handler.class,
      method : Method = Method::Any,
      accept : String = "",
      content_type : String = ""
    )
      resource = "/#{method.to_s.downcase}#{path}"
      RADIX.add resource, Route.new(endpoint.new, resource, method, accept, content_type)
    rescue ex : Radix::Tree::DuplicateError
      raise DuplicateRoute.new(method, path, endpoint.new)
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
