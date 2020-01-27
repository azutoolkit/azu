module Azu
  class Render
    include HTTP::Handler

    def call(context)
      route = context.request.route.not_nil!
      _endpoint, endpoint = route.payload
      context.response.output << endpoint.new(context, route.params).call
    end

    protected def path(context)
      upgrade_path(context) + context.request.method.downcase + context.request.path.rstrip('/')
    end

    protected def upgrade_path(context)
      return "/ws" if context.request.headers.includes_word?("Upgrade", "Websocket")
      "/"
    end
  end
end
