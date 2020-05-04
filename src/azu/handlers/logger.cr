require "colorize"

module Azu
  class Logger
    include HTTP::Handler
    getter log : ::Log

    getter blue = Colorize::ColorRGB.new(65, 122, 179)
    getter light_blue = Colorize::ColorRGB.new(193, 221, 255)
    getter yellow = Colorize::ColorRGB.new(207, 173, 0)
    getter white = Colorize::ColorRGB.new(197, 200, 198)
    getter green = Colorize::ColorRGB.new(93, 166, 2)

    def initialize(@log : ::Log = CONFIG.log)
      Log::Formatter.new do |entry, io|
        io << entry.timestamp.to_s("%I:%M:%S").colorize(blue)
        io << " AZU | ".colorize(blue).bold
        io << "#{entry.severity}".colorize(light_blue)
        io << " Source: #{entry.source} "
        io << entry.message.colorize(white)
      end
    end

    def call(context : HTTP::Server::Context)
      call_next(context)
      spawn do
        log.info { message(context) }
      end
      context
    end

    private def message(context)
      time = Time.local
      String.build do |str|
        str << '\u21e5'.colorize(blue) if Colorize.enabled?
        str << " Method: "
        str << context.request.method.colorize(green)
        str << " Path: "
        str << context.request.resource.colorize(light_blue).underline
        str << " "
        str << '\u21c4'.colorize(green) if Colorize.enabled?
        str << " Status: "
        str << http_status(context.response.status_code)
        str << " Duration: "
        str << elapsed(Time.local - time).colorize(blue)
        str << " Latency: "
        str << (Time.local - time).colorize(blue)
        str << " Headers: "
        str << context.request.headers.to_json
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

    private def severity(severity)
      case severity
      when Log::Severity::INFO  then severity.colorize(:green)
      when Log::Severity::DEBUG then severity.colorize(:blue)
      when Log::Severity::WARN  then severity.colorize(:yellow)
      when Log::Severity::ERROR then severity.colorize(:red)
      when Log::Severity::FATAL then severity.colorize(:red).bold.underline
      else
        severity.colorize(:white)
      end
    end
  end
end
