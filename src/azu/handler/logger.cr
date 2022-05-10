require "colorize"

module Azu
  module Handler
    class Logger
      include HTTP::Handler

      getter log : ::Log

      def initialize(@log : ::Log = CONFIG.log)
      end

      def call(context : HTTP::Server::Context)
        start = Time.monotonic

        begin
          call_next(context)
        ensure
          elapsed = Time.monotonic - start
          elapsed_text = elapsed(elapsed)

          req = context.request
          res = context.response

          addr =
            case remote_address = req.remote_address
            when nil
              "-"
            when Socket::IPAddress
              remote_address.address
            else
              remote_address
            end

          @log.info { message(addr, req, res, elapsed_text) }
        end
      end

      private def message(addr, req, res, elapsed_text)
        String.build do |str|
          str << addr.colorize(:green).underline
          str << entry(:Address, addr, :green)
          str << entry(:Method, req.method, :green)
          str << entry(:Path, req.resource, :light_blue)
          str << status(:Status, http_status(res.status_code))
          str << entry(:Latency, elapsed_text, :green)
        end
      end

      private def elapsed(elapsed)
        millis = elapsed.total_milliseconds
        return "#{millis.round(2)}ms" if millis >= 1
        "#{(millis * 1000).round(2)}µs"
      end

      private def entry(key, message, color)
        String.build do |str|
          str << " ⤑ ".colorize(:green)
          str << "#{key}: ".colorize(:white)
          str << message.colorize(color)
        end
      end

      private def status(key, message)
        String.build do |str|
          str << " ⤑ ".colorize(:green)
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
        else               status.colorize(:white)
        end
      end
    end
  end
end
