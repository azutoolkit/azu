require "http/server/handler"

module Azu
  module Handler
    # Adds the response headers that close common browser-side holes. A header the application
    # already set on the response is left alone, so one endpoint can loosen a policy.
    #
    # `Strict-Transport-Security` is sent only with `hsts: true`, because browsers remember it and a
    # plain-HTTP deployment would lock itself out. `Content-Security-Policy` is off unless given,
    # since a policy that fits every application does not exist.
    class SecurityHeaders
      include HTTP::Handler

      HSTS_VALUE = "max-age=31536000; includeSubDomains"

      def initialize(
        @frame_options : String = "SAMEORIGIN",
        @referrer_policy : String = "strict-origin-when-cross-origin",
        @content_security_policy : String? = nil,
        @hsts : Bool = false,
      )
      end

      def call(context : HTTP::Server::Context)
        headers = context.response.headers
        headers["X-Content-Type-Options"] = "nosniff" unless headers.has_key?("X-Content-Type-Options")
        headers["X-Frame-Options"] = @frame_options unless headers.has_key?("X-Frame-Options")
        headers["Referrer-Policy"] = @referrer_policy unless headers.has_key?("Referrer-Policy")
        @content_security_policy.try { |policy| headers["Content-Security-Policy"] = policy unless headers.has_key?("Content-Security-Policy") }
        headers["Strict-Transport-Security"] = HSTS_VALUE if @hsts && !headers.has_key?("Strict-Transport-Security")

        call_next(context)
      end
    end
  end
end
