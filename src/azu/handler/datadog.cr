module Azu
  module Handler
    class Datadog
      include HTTP::Handler

      def call(context)
        resource = "#{context.request.method} #{context.request.path}"
        Datadog.integration(%w[azu]).trace "http.request", resource: resource do |span|
          call_next(context)

          span["http.method"] = context.request.method
          span["http.request_id"] = context.response.headers["X-Request-ID"]?.to_s
          span["http.server_name"] = context.request.headers["host"]?.to_s
          span["http.client_ip"] = context.request.headers["x-forward-for"]? || context.request.remote_address.as(Socket::IPAddress).address.to_s
          span["http.user_agent"] = context.request.headers["user-agent"]?.to_s
          span["http.path"] = context.request.path
          span["http.target"] = context.request.resource
          span["http.flavor"] = context.request.version
          span["http.host"] = context.request.headers["host"].to_s
          span["http.status_code"] = context.response.status_code.to_s
        end
      end
    end
  end
end
