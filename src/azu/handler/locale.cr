module Azu
  module Handler
    # Serves each request in the locale that best matches its `Accept-Language` header.
    #
    # The locale is chosen among `Helpers::I18n.available_locales`, falling back to the default
    # locale, and applies to everything the request does, including template rendering.
    #
    # It is scoped with `Helpers::I18n.with_locale`, so it ends with the request. A connection's
    # fiber serves many requests in turn, and one request's locale, including one assigned with
    # `Helpers::I18n.locale=` while handling it, never reaches the next.
    #
    # ```
    # MyApp.start [ # a module that includes Azu
    #   Azu::Handler::RequestId.new,
    #   Azu::Handler::Locale.new,
    #   Azu::Handler::Rescuer.new,
    # ] of HTTP::Handler
    # ```
    class Locale
      include HTTP::Handler

      # Only the first ranges of a header can matter, and the rest is client-controlled input.
      MAX_RANGES = 20

      def call(context : HTTP::Server::Context)
        locale = self.class.negotiate(context.request.headers["Accept-Language"]?)

        Helpers::I18n.with_locale(locale) { call_next(context) }
      end

      # The available locale that best matches the header, or the default one.
      #
      # Ranges are tried by quality (ties by position in the header, `q=0` never matches). A range
      # matches an available locale with the same tag (`en-US` and `en-us` are the same), else one
      # for its language alone (`en-GB` is served `en`), else a regional variant of that language
      # (`pt` is served `pt-BR`). `*` accepts anything, so it leaves the default.
      def self.negotiate(
        header : String?,
        available : Array(String) = Helpers::I18n.available_locales,
        default : String = Helpers::I18n.default_locale,
      ) : String
        return default unless header

        ranges(header).each do |range|
          if locale = best_match(range, available)
            return locale
          end
        end

        default
      end

      private def self.ranges(header : String) : Array(String)
        header.split(',').first(MAX_RANGES).each_with_index.compact_map do |part, index|
          tag, _, params = part.partition(';')
          tag = tag.strip
          quality = quality(params)

          {tag, quality, index} unless tag.empty? || quality <= 0
        end.to_a.sort_by { |_, quality, index| {-quality, index} }.map(&.first)
      end

      # The `q` weight of a range (1.0 when absent); a malformed one counts as 0, so the range is skipped.
      private def self.quality(params : String) : Float64
        params.split(';').each do |param|
          name, _, value = param.partition('=')
          return value.strip.to_f? || 0.0 if name.strip == "q"
        end

        1.0
      end

      private def self.best_match(range : String, available : Array(String)) : String?
        return if range == "*"

        tag = range.downcase
        language = tag.partition('-').first

        available.find { |locale| locale.downcase == tag } ||
          available.find { |locale| locale.downcase == language } ||
          available.find { |locale| locale.downcase.partition('-').first == language }
      end
    end
  end
end
