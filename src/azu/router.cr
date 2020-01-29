module Azu
  class Router
    alias Path = String
    ROUTES    = Radix::Tree(Tuple(Symbol, Endpoint.class)).new
    RESOURCES = %w(connect delete get head options patch post put trace)

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
      {% end %}

      {% if !%w(trace connect options head).includes? method %}
      add path, endpoint, namespace, Method::Options if method.add_options?
      {% end %}
    end
    {% end %}
    
    def root(endpoint : Endpoint.class)
      ROUTES.add "/", {:root, endpoint}
    end

    def add(path : Path, endpoint : Endpoint.class, namespace : Symbol, method : Method)
      ROUTES.add "/#{method.to_s.downcase}#{path}", {namespace, endpoint}
    rescue ex : Radix::Tree::DuplicateError
      raise DuplicateRoute.new(namespace, method, path, endpoint)
    end
  end
end
