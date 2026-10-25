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

      # The headers to send, keyed as `HTTP::Headers` stores them. Their values are checked once, here, so a request
      # neither checks them again nor hashes a name only to learn that the response does not have it yet.
      @headers : Array({HTTP::Headers::Key, String})

      # Raises `ArgumentError` for a value a header cannot carry (a line break, for one).
      def initialize(
        frame_options : String = "SAMEORIGIN",
        referrer_policy : String = "strict-origin-when-cross-origin",
        content_security_policy : String? = nil,
        hsts : Bool = false,
      )
        headers = HTTP::Headers{"X-Content-Type-Options" => "nosniff", "X-Frame-Options" => frame_options, "Referrer-Policy" => referrer_policy}
        content_security_policy.try { |policy| headers["Content-Security-Policy"] = policy }
        headers["Strict-Transport-Security"] = HSTS_VALUE if hsts
        @headers = headers.map { |name, values| {HTTP::Headers::Key.new(name), values.first} }
      end

      def call(context : HTTP::Server::Context)
        headers = context.response.headers
        # One pass over the headers set before this handler (in the default stack, X-Request-ID alone) finds ours,
        # comparing names as HTTP::Headers does
        present = 0
        headers.each_key do |name|
          @headers.each_with_index { |(key, _), index| present |= 1 << index if key == name }
        end
        # A Key goes straight to the hash HTTP::Headers forwards to: one hash of the name, no second check of the value
        @headers.each_with_index { |(key, value), index| headers[key] = value if present.bit(index) == 0 }

        call_next(context)
      end
    end
  end
end
