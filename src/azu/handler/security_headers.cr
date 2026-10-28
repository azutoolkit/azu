require "http/server/handler"

module Azu
  module Handler
    # Adds the response headers that close common browser-side holes. A header the application
    # already set on the response is left alone, so one endpoint can loosen a policy.
    #
    # `Strict-Transport-Security` is sent with `hsts: true`, or with `hsts: :auto` to the requests a proxy
    # forwarded as `X-Forwarded-Proto: https` (the default stack passes `true` when this app terminates TLS itself,
    # `:auto` otherwise). Never on plain HTTP, because browsers remember it and a plain-HTTP deployment would lock
    # itself out. `Content-Security-Policy` is off unless given, since a policy that fits every application does
    # not exist. `Permissions-Policy`, `Cross-Origin-Opener-Policy` and `Cross-Origin-Resource-Policy` have
    # conservative defaults an application can replace or switch off with nil.
    class SecurityHeaders
      include HTTP::Handler

      HSTS_VALUE = "max-age=31536000; includeSubDomains"
      # The browser features a page may not use unless the application allows them.
      PERMISSIONS_POLICY = "camera=(), microphone=(), geolocation=()"
      # Isolates the browsing context from cross-origin openers but keeps the popups the page opens itself
      # reachable (sign-in popups rely on `window.opener`).
      OPENER_POLICY = "same-origin-allow-popups"
      # Other sites cannot embed the responses as images, scripts or frames; the same site's other subdomains
      # and ports can, and a CORS request is not affected.
      RESOURCE_POLICY = "same-site"

      # The headers to send, keyed as `HTTP::Headers` stores them. Their values are checked once, here, so a request
      # neither checks them again nor hashes a name only to learn that the response does not have it yet.
      @headers : Array({HTTP::Headers::Key, String})
      @hsts_auto = false
      @hsts_key = TrustedHeader.key("Strict-Transport-Security")

      # Raises `ArgumentError` for a value a header cannot carry (a line break, for one), or an `hsts` that is
      # neither a Bool nor `:auto`.
      def initialize(
        frame_options : String = "SAMEORIGIN",
        referrer_policy : String = "strict-origin-when-cross-origin",
        content_security_policy : String? = nil,
        hsts : Bool | Symbol = false,
        permissions_policy : String? = PERMISSIONS_POLICY,
        cross_origin_opener_policy : String? = OPENER_POLICY,
        cross_origin_resource_policy : String? = RESOURCE_POLICY,
      )
        raise ArgumentError.new("hsts: #{hsts.inspect} is neither true, false nor :auto") unless hsts.is_a?(Bool) || hsts == :auto
        headers = HTTP::Headers{"X-Content-Type-Options" => "nosniff", "X-Frame-Options" => frame_options, "Referrer-Policy" => referrer_policy}
        permissions_policy.try { |policy| headers["Permissions-Policy"] = policy }
        cross_origin_opener_policy.try { |policy| headers["Cross-Origin-Opener-Policy"] = policy }
        cross_origin_resource_policy.try { |policy| headers["Cross-Origin-Resource-Policy"] = policy }
        content_security_policy.try { |policy| headers["Content-Security-Policy"] = policy }
        case hsts
        when true  then headers["Strict-Transport-Security"] = HSTS_VALUE
        when :auto then @hsts_auto = true
        end
        @headers = headers.map { |name, values| {TrustedHeader.key(name), values.first} }
      end

      def call(context : HTTP::Server::Context)
        headers = context.response.headers
        # One pass over the headers set before this handler (in the default stack, X-Request-ID alone) finds ours,
        # comparing names as HTTP::Headers does (through the internals TrustedHeader names)
        present = 0
        hsts_present = false
        TrustedHeader.each_key(headers) do |name|
          @headers.each_with_index { |(key, _), index| present |= 1 << index if key == name }
          hsts_present = true if @hsts_auto && name == @hsts_key
        end
        @headers.each_with_index { |(key, value), index| TrustedHeader.set(headers, key, value) if present.bit(index) == 0 }
        TrustedHeader.set(headers, @hsts_key, HSTS_VALUE) if @hsts_auto && !hsts_present && secure?(context.request)

        call_next(context)
      end

      # True when a proxy forwarded the request as https (the first `X-Forwarded-Proto` value, whatever its case).
      # Only the header is read: the config is not consulted on the request path, the stack decides that when it is built.
      private def secure?(request : HTTP::Request) : Bool
        request.headers["X-Forwarded-Proto"]?.try { |proto| proto.split(',').first.strip.compare("https", case_insensitive: true) == 0 } || false
      end
    end
  end
end
