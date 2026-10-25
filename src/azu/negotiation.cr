require "mime"
require "mime/media_type"

module Azu
  # Picks the representation of a response from the `Accept` header (RFC 9110 section 12): the
  # formats a response can render are matched against the media ranges the client lists, the best
  # `q` wins, and a more specific range beats a general one for the same format.
  module Negotiation
    enum Format
      Html
      Json
      Xml
      Text

      def media_type : String
        case self
        in .html? then "text/html"
        in .json? then "application/json"
        in .xml?  then "application/xml"
        in .text? then "text/plain"
        end
      end

      # The `Content-Type` a response of this format is sent with.
      def content_type : String
        html? || text? ? "#{media_type}; charset=utf-8" : media_type
      end

      # The format named by a `?format=` value: `json`, `html`, `xml`, `text` or `txt`.
      def self.named?(name : String) : Format?
        name = "text" if name.downcase == "txt"
        parse?(name)
      end
    end

    # One entry of an `Accept` header: `text/html;q=0.8` is `MediaRange.new("text", "html", 0.8, 0)`.
    record MediaRange, type : String, subtype : String, quality : Float64, position : Int32 do
      # 2 for `text/html`, 1 for `text/*`, 0 for `*/*`.
      def specificity : Int32
        (type == "*" ? 0 : 1) + (subtype == "*" ? 0 : 1)
      end

      def matches?(media_type : String) : Bool
        kind, _, sub = media_type.partition('/')
        (type == "*" || type == kind) && (subtype == "*" || subtype == sub)
      end
    end

    # The media ranges of an `Accept` header, in the order the client wrote them. Entries that are
    # not media ranges are skipped, so a header with no valid entry yields none, the same as no header.
    def self.ranges(header : String?) : Array(MediaRange)
      return [] of MediaRange unless header

      ranges = [] of MediaRange
      header.split(',').each do |entry|
        range = media_range(entry, ranges.size) || next
        ranges << range
      end
      ranges
    end

    # Whether the client asks for `application/problem+json` at least as eagerly as for plain JSON (`application/json`,
    # or a wildcard that covers it): it is named with a `q` above zero and no JSON range has a higher one. A
    # substring of the header is not enough (`application/json, application/problem+json;q=0.1` wants plain JSON).
    def self.prefers_problem?(header : String?) : Bool
      ranges = ranges(header)
      problem = ranges.select { |range| range.type == "application" && range.subtype == "problem+json" }.max_of?(&.quality)
      return false if problem.nil? || problem <= 0

      json = ranges.select(&.matches?("application/json")).max_of?(&.quality) || 0.0
      problem >= json
    end

    # The format to answer with, or nil when the client accepts none of `formats`. `formats` is in
    # order of preference: the first is what a request without `Accept`, or with `*/*`, gets. A
    # `?format=json` in the query string takes the place of the header (nil when the response lacks
    # that format).
    def self.negotiate(formats : Array(Format), request : HTTP::Request) : Format?
      if requested = requested_format(request)
        return requested if formats.includes?(requested)
        return
      end

      ranges = ranges(request.headers["Accept"]?)
      return formats.first? if ranges.empty?

      rated = formats.each_with_index.compact_map { |format, rank| rating(format, rank, ranges).try { |score| {score, format} } }
      rated.max_by?(&.first).try(&.last)
    end

    # Like `negotiate`, raising `Response::NotAcceptable` (a 406 listing what can be rendered) when nothing matches.
    def self.negotiate!(formats : Array(Format), request : HTTP::Request) : Format
      negotiate(formats, request) || raise Response::NotAcceptable.new(formats.map(&.media_type))
    end

    # Tells caches that the answer depends on the `Accept` header.
    def self.vary(response : HTTP::Server::Response) : Nil
      return if response.headers.includes_word?("Vary", "Accept")
      response.headers.add("Vary", "Accept")
    end

    # The format `?format=` names (the parameter is `Configuration#format_parameter`). A value that
    # is not a format name, such as `?format=csv` meant for the endpoint, is left alone.
    private def self.requested_format(request : HTTP::Request) : Format?
      parameter = Azu.current_config.format_parameter || return
      request.query_params[parameter]?.try { |name| Format.named?(name) }
    end

    private def self.media_range(entry : String, position : Int32) : MediaRange?
      return if entry.blank?

      media = MIME::MediaType.parse(entry.strip)
      type, _, subtype = media.media_type.partition('/')
      return if subtype.empty?

      quality = media["q"]?.try(&.to_f?).try { |value| value if value.finite? } || 1.0
      quality = quality.clamp(0.0, 1.0)
      MediaRange.new(type, subtype, quality, position)
    rescue MIME::Error
      nil
    end

    # What a format scores: the quality of the most specific range matching it, then that range's
    # specificity, its position in the header, and finally the format's rank. Nil when no range
    # matches or the client refused it with `q=0`.
    private def self.rating(format : Format, rank : Int32, ranges : Array(MediaRange)) : {Float64, Int32, Int32, Int32}?
      range = ranges.select(&.matches?(format.media_type)).max_by?(&.specificity)
      return if range.nil? || range.quality <= 0

      {range.quality, range.specificity, -range.position, -rank}
    end
  end
end
