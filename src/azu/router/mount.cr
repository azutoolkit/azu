require "http/server"

module Azu
  class Router
    # Routes everything below a path to another app's router, with that path removed and that
    # app's configuration current.
    class Mount
      include Routable

      # The configuration of the app served below the mount path.
      getter child : Configuration

      def initialize(@parent : Router, @child : Configuration, @at : String)
      end

      # The path clients see this mount under, including the prefixes of the routers above it.
      def prefix : String
        @parent.mount_prefix + @at
      end

      # Checks whether the request path under this mount targets a `public: true` route in the child router.
      def public_route?(context : HTTP::Server::Context) : Bool
        request = context.request
        original = request.path
        prev_resolved = context.azu_match_resolved?
        prev_match = context.azu_resolved_match
        request.path = original.lchop(@at).presence || "/"
        context.azu_match_resolved = false
        context.azu_resolved_match = nil
        begin
          Azu.with_config(@child) { @child.router.public_route?(context) }
        ensure
          request.path = original
          context.azu_match_resolved = prev_resolved
          context.azu_resolved_match = prev_match
        end
      end

      def call(context : HTTP::Server::Context)
        request = context.request
        original = request.path
        params = request.path_params?
        prev_resolved = context.azu_match_resolved?
        prev_match = context.azu_resolved_match
        request.path = original.lchop(@at).presence || "/"
        context.azu_match_resolved = false
        context.azu_resolved_match = nil
        begin
          Azu.with_config(@child) { @child.router.process(context) }
        ensure
          request.path = original
          request.path_params = params # the child's router wrote its own
          context.azu_match_resolved = prev_resolved
          context.azu_resolved_match = prev_match
        end
        context
      end
    end
  end
end
