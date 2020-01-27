module Azu
  class Router
    alias Path = String
    ROUTES    = Radix::Tree(Tuple(Symbol, Endpoint.class)).new
    RESOURCES = %w(connect delete get head options patch post put trace)

    class RouteNotFound < Azu::Error(404)
    end

    class DuplicateRoute < Exception
      def initialize(@namespace : Symbol, @method : Method, @path : Path, @endpoint : Endpoint.class)
        super "namespace: #{namespace}, http_method: #{method}, path: #{path}, endpoint: #{endpoint}"
      end
    end

    {% for method in RESOURCES %}
    def {{method.id}}(namespace : Symbol, path : Path, endpoint : Endpoint)
      method = Method.parse({{method}})
      add namespace, method, path, endpoint

      {% if method == "get" %}
      add namespace, Method::Head, path, endpoint 
      {% end %}

      {% if !%w(trace connect options head).includes? method %}
      add namespace, Method::Options, path, endpoint if method.add_options?
      {% end %}
    end
    {% end %}

    def add(namespace : Symbol, method : Method, path : Path, endpoint : Endpoint.class)
      ROUTES.add "/#{method.to_s.downcase}#{path}", {namespace, endpoint}
    rescue ex : Radix::Tree::DuplicateError
      raise DuplicateRoute.new(namespace, method, path, endpoint)
    end
  end
end
