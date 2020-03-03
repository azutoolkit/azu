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
        io << "Progname: " << progname << ", "
        io << "Severity: " << severity << ", "
        io << message.colorize(white)
      end
    end

    def call(context : HTTP::Server::Context)
      call_next(context)
      spawn { log.info message(context) }
      context
    end

    private def message(context)
      time = Time.local

      String.build do |s|
        s << "Time:" << time << ", "
        s << "Method:" << context.request.method << ", "
        s << "Resource:" << context.request.resource << ", "
        s << "Status:" << context.response.status_code  << ", "
        s << "Latency:" << elapsed(Time.local - time) << ", "
        s << "Duration:" << (Time.local - time) << ", "
        s << "Host:" << context.request.host << ", "
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
