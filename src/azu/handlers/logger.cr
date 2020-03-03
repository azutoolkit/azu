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

    def initialize(@log : ::Logger = Azu.log)
      @log.formatter = Logger::Formatter.new do |severity, datetime, progname, message, io|
        io << datetime.to_s("%I:%M:%S").colorize(blue)
        io << " AZU | ".colorize(blue).bold
        io << "#{severity(severity)}".colorize(light_blue)
        io << " "
        io << message.colorize(white)
      end
    end

    def call(context : HTTP::Server::Context)
      call_next(context)
      log.info message(context)
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
      when Logger::Severity::INFO  then severity.colorize(:green)
      when Logger::Severity::DEBUG then severity.colorize(:blue)
      when Logger::Severity::WARN  then severity.colorize(:yellow)
      when Logger::Severity::ERROR then severity.colorize(:red)
      when Logger::Severity::FATAL then severity.colorize(:red).bold.underline
      else
        severity.colorize(:white)
      end
    end
  end
end
