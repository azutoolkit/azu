require "http/server"

module Azu
  class Router
    # Routes everything below a path to another app's router, with that path removed and that
    # app's configuration current.
    class Mount
      include Routable

      def initialize(@parent : Router, @child : Configuration, @at : String)
      end

      # The path clients see this mount under, including the prefixes of the routers above it.
      def prefix : String
        @parent.mount_prefix + @at
      end

      def call(context : HTTP::Server::Context)
        request = context.request
        original = request.path
        request.path = original.lchop(@at).presence || "/"
        begin
          Azu.with_config(@child) { @child.router.process(context) }
        ensure
          request.path = original
        end
        context
      end
    end
  end
end
