require "http/server/handler"
require "json"

module Azu
  module Handler
    # Answers `GET /health` (or `path`) for load balancers and orchestrators without reaching the
    # rest of the chain. It reports `200 {"status":"ok"}` while every named check passes and
    # `503` with the failing names otherwise. A check that raises counts as failing.
    #
    # ```
    # Azu::Handler::HealthCheck.new(checks: {"database" => -> { DB.ping }})
    # ```
    class HealthCheck
      include HTTP::Handler

      alias Check = Proc(Bool)

      def initialize(@path : String = "/health", @checks : Hash(String, Check) = {} of String => Check)
      end

      def call(context : HTTP::Server::Context)
        return call_next(context) unless context.request.path == @path && {"GET", "HEAD"}.includes?(context.request.method)

        failing = @checks.keys.reject { |name| passes?(name) }
        context.response.status_code = failing.empty? ? 200 : 503
        context.response.content_type = "application/json"
        context.response << (failing.empty? ? {status: "ok"}.to_json : {status: "unavailable", failing: failing}.to_json)
      end

      private def passes?(name : String) : Bool
        @checks[name].call
      rescue
        false
      end
    end
  end
end
