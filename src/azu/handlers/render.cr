module Azu
  class Render
    include HTTP::Handler

    def call(context)
      route = context.request.route
      _, endpoint = route.payload

      if view = endpoint.new(context, route.params).call
        return context if context.request.ignore_body?
        return context if (300..308).includes? context.response.status_code

        context.response.output << ContentNegotiator.content(context, view)
      end

      call_next(context) if self.next

      context
    end
  end
end
