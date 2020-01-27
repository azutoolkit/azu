require "colorize"

module Azu
  class LogHandler
    include HTTP::Handler
    getter log : ::Logger

    getter blue = Colorize::ColorRGB.new(65, 122, 179)
    getter light_blue = Colorize::ColorRGB.new(193, 221, 255)
    getter yellow = Colorize::ColorRGB.new(207, 173, 0)
    getter white = Colorize::ColorRGB.new(197, 200, 198)
    getter green = Colorize::ColorRGB.new(93, 166, 2)

    def initialize(@log : ::Logger)
    end

    def call(context : HTTP::Server::Context)
      call_next(context)
      log.info message(context)
      context
    end

    private def message(context)
      time = Time.local
      String.build do |str|
        str << '\u21e5'.colorize(blue)
        str << " "
        str << context.request.method.colorize(green)
        str << " "
        str << context.request.resource.colorize(light_blue).underline()
        str << " at ".colorize(white)
        str << time.colorize(yellow)
        str << " "
        str << '\u21c4'.colorize(green)
        str << " "
        str << " Responded with "
        str << http_status(context.response.status_code)
        str << " in "
        str << elapsed(Time.local - time).colorize(blue)
      end
    end

    private def elapsed(elapsed)
      millis = elapsed.total_milliseconds
      return "#{millis.round(2)}ms" if millis >= 1

      "#{(millis * 1000).round(2)}µs"
    end

    private def http_status(status)
      case status
      when 200..299 then status.colorize(:green)
      when 300..399 then status.colorize(:blue)
      when 400..499 then status.colorize(:yellow)
      when 500..599 then status.colorize(:red)
      else
        status.colorize(:white)
      end
    end
  end
end
