module Azu
  class Router
    # Declares routes on a router, the way `App#routes` does:
    #
    # ```
    # app.routes do
    #   get "/users/:id", UserEndpoint
    #   scope "/api", role: :viewer do
    #     post "/users", CreateUserEndpoint, role: :operator
    #   end
    #   mount admin_app, at: "/admin"
    # end
    # ```
    #
    # Inside a `scope` every path, including those of mounts, starts with the scope's prefix,
    # and routes inherit any scope-level access or hygiene options unless they specify their own.
    class Builder
      def initialize(
        @router : Router,
        @prefix : String = "",
        @defaults : RouteOptions = RouteOptions.new,
      )
      end

      {% for method in Router::RESOURCES %}
        def {{method.id}}(
          path : Path,
          endpoint : T,
          options : RouteOptions? = nil,
          **opts,
        ) : Nil forall T
          call_opts = options || RouteOptions.new(**opts)
          @router.{{method.id}}(prefixed(path), endpoint, call_opts, scope_options: @defaults)
        end
      {% end %}

      # Registers every route the verb macros declared inside `target` (an endpoint type or instance),
      # below this builder's prefix:
      #
      # ```
      # app.routes do
      #   scope "/v1" do
      #     endpoint UsersEndpoint
      #     endpoint ListQueuesEndpoint.new(queues)
      #   end
      # end
      # ```
      def endpoint(
        target : T,
        options : RouteOptions? = nil,
        **opts,
      ) : Nil forall T
        call_opts = options || RouteOptions.new(**opts)
        @router.endpoint(target, call_opts, prefix: @prefix, scope_options: @defaults)
      end

      def ws(
        path : Path,
        channel : Channel.class,
        options : RouteOptions? = nil,
        **opts,
      ) : Nil
        call_opts = options || RouteOptions.new(**opts)
        @router.ws(prefixed(path), channel, call_opts, scope_options: @defaults)
      end

      def scope(
        prefix : Path = "",
        options : RouteOptions? = nil,
        **opts,
        &
      ) : Nil
        next_prefix = prefix.empty? ? @prefix : prefixed(prefix.rstrip('/'))
        scope_opts = options || RouteOptions.new(**opts)
        child_builder = Builder.new(@router, next_prefix, @defaults.merge(scope_opts))
        with child_builder yield
      end

      def mount(app : App, at path : Path) : Nil
        @router.mount app.config, at: prefixed(path)
      end

      # Registers Authly's OAuth 2.0 and OpenID Connect provider endpoints below this builder's prefix.
      def mount_authly(handler : HTTP::Handler? = nil) : Nil
        @router.mount_authly(handler, prefix: @prefix, scope_options: @defaults)
      end

      private def prefixed(path : Path) : String
        path == "/" && !@prefix.empty? ? @prefix : @prefix + path
      end
    end
  end
end
