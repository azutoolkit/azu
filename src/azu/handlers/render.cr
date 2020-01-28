module Azu
  class Render
    include HTTP::Handler

    def call(context)
      route = context.request.route.not_nil!
      _namespace, endpoint = route.payload
      context.response.output << endpoint.new(context, route.params).call
    end
  end
end
