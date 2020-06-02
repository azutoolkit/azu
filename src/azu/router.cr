require "http/web_socket"

module Azu
  class Router
    alias Path = String
    ROUTES    = Set(Route).new
    SOCKETS   = Set(Socket).new
    RESOURCES = %w(connect delete get head options patch post put trace)

    record Route, namespace : Symbol, endpoint : Endpoint, resource : String
    record Socket, namespace : Symbol, channel : HTTP::WebSocketHandler, resource : String

    class DuplicateRoute < Exception
      def initialize(@namespace : Symbol, @method : Method, @path : Path, @endpoint : Endpoint.class)
        super "namespace: #{namespace}, http_method: #{method}, path: #{path}, endpoint: #{endpoint}"
      end
    end

    class Builder
      def initialize(@router : Router, @namespace : Symbol, @scope : String = "")
      end

      {% for method in RESOURCES %}
      def {{method.id}}(path : Path, endpoint : Endpoint.class)
        @router.{{method.id}}("#{@scope}#{path}", endpoint, @namespace)
      end
      {% end %}
    end

    def routes(namespace : Symbol, scope : String = "")
      with Builder.new(self, namespace, scope) yield
    end

    {% for method in RESOURCES %}
    def {{method.id}}(path : Path, endpoint : Endpoint.class, namespace : Symbol)
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

    def root(namespace : Symbol, endpoint : Endpoint.class)
      ROUTES.add Route.new(namespace: namespace, endpoint: endpoint.new, resource: "/get/")
    end

    def ws(path : String, channel : Channel.class)
      handler = HTTP::WebSocketHandler.new do |socket, context|
        channel.new(socket).call(context)
      end

      SOCKETS.add Socket.new(:websocket, handler, "/ws#{path}")
    end

    def add(path : Path, endpoint : Endpoint.class, namespace : Symbol, method : Method)
      ROUTES.add Route.new(namespace: namespace, endpoint: endpoint.new, resource: "/#{method.to_s.downcase}#{path}")
    rescue ex : Radix::Tree::DuplicateError
      raise DuplicateRoute.new(namespace, method, path, endpoint)
    end
  end
end
