require "colorize"

module Azu
  module Handler
    class SimpleLogger
      include HTTP::Handler

      getter log : ::Log

      def initialize(@log : ::Log = CONFIG.log)
      end

      def call(context : HTTP::Server::Context)
        call_next(context)
        spawn do
          log.info { message(context) }
        end
        context
      end

      private def message(context)
        time = Time.monotonic
        String.build do |str|
          str << "HTTP Request".colorize(:green).underline
          str << entry(:Method, context.request.method, :green)
          str << entry(:Path, context.request.resource, :light_blue)
          str << status_entry(:Status, http_status(context.response.status_code))
          str << entry(:Latency, elapsed(Time.monotonic - time), :green)
        end
      end

      private def format_hash(title, h, str)
        str << "  #{title}".colorize(:light_gray).bold.underline

        h.map do |k, v|
          str << " • ".colorize(:light_gray)
          str << "#{k}: ".colorize(:white)
          str << case v
          when Hash  then format_hash("Sub", v, str)
          when Array then v.join(", ").colorize(:cyan)
          else            v.colorize(:cyan)
          end
        end

        str
      end

      private def elapsed(elapsed)
        millis = elapsed.total_milliseconds
        return "#{millis.round(2)}ms" if millis >= 1

        "#{(millis * 1000).round(2)}µs"
      end

      private def entry(key, message, color)
        String.build do |str|
          str << " • ".colorize(:green)
          str << "#{key}: ".colorize(:white)
          str << message.colorize(color)
        end
      end

      private def status_entry(key, message)
        String.build do |str|
          str << " • ".colorize(:green)
          str << "#{key}: ".colorize(:white)
          str << message
        end
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
end
