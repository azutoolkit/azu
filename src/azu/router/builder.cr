module Azu
  class Router
    # Declares routes on a router, the way `App#routes` does:
    #
    # ```
    # app.routes do
    #   get "/users/:id", UserEndpoint
    #   scope "/api" do
    #     post "/users", CreateUserEndpoint
    #   end
    #   mount admin_app, at: "/admin"
    # end
    # ```
    #
    # Inside a `scope` every path, including those of mounts, starts with the scope's prefix.
    class Builder
      def initialize(@router : Router, @prefix : String = "")
      end

      {% for method in Router::RESOURCES %}
        def {{method.id}}(path : Path, endpoint : Routable) : Nil
          @router.{{method.id}} prefixed(path), endpoint
        end

        def {{method.id}}(path : Path, endpoint : T.class) : Nil forall T
          {{method.id}} path, endpoint.new
        end
      {% end %}

      # Registers every route the verb macros declared inside `type`, below this builder's prefix. The
      # same endpoint type can be registered on several apps, each with its own prefix:
      #
      # ```
      # app.routes { scope("/v1") { endpoint UsersEndpoint } }
      # ```
      def endpoint(type : T.class) : Nil forall T
        raise ArgumentError.new("#{type} declares no routes: add get/post/... to its body") if type.routes.empty?
        type.routes.each { |(verb, path)| @router.register verb, prefixed(path), type.new }
      end

      def ws(path : Path, channel : Channel.class) : Nil
        @router.ws prefixed(path), channel
      end

      def scope(prefix : Path, &) : Nil
        with Builder.new(@router, prefixed(prefix.rstrip('/'))) yield
      end

      def mount(app : App, at path : Path) : Nil
        @router.mount app.config, at: prefixed(path)
      end

      private def prefixed(path : Path) : String
        path == "/" && !@prefix.empty? ? @prefix : @prefix + path
      end
    end
  end
end
