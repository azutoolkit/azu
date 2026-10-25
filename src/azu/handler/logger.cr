require "colorize"
require "http/server/handler"
require "../log_text"

module Azu
  module Handler
    class Logger
      include HTTP::Handler

      # Without an explicit log, the log of the app serving the request (`Azu.current_config`).
      def initialize(@log : ::Log? = nil)
      end

      def log : ::Log
        @log || Azu.current_config.log
      end

      def call(context : HTTP::Server::Context)
        start = Time.instant

        begin
          call_next(context)
        ensure
          elapsed = Time.instant - start
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

          log.info { message(addr, req, res, elapsed_text) }
        end
      end

      private def message(addr, req, res, elapsed_text)
        String.build do |str|
          str << addr.colorize(:green).underline
          str << " ⤑ "
          str << req.method.colorize(:yellow)
          str << entry(:Path, LogText.target(req.resource), :light_blue)
          str << entry(:Endpoint, get_endpoint_class_name(req), :magenta)
          str << status(:Status, res.status_code)
          str << entry(:Latency, elapsed_text, :green)
        end
      end

      private def get_endpoint_class_name(req : HTTP::Request) : String
        endpoint_name = LogText.safe(req.headers["X-Azu-Endpoint"]? || "unknown", LogText::REASON_LENGTH)
        # Simplify the class name by removing module prefixes for readability
        endpoint_name.split("::").last
      end

      private def elapsed(elapsed)
        millis = elapsed.total_milliseconds
        return "#{millis.round(2)}ms" if millis >= 1
        "#{(millis * 1000).round(2)}µs"
      end

      private def entry(key, message, color)
        String.build do |str|
          str << " #{key}: "
          str << message.colorize(color)
        end
      end

      private def status(key, message)
        String.build do |str|
          str << " #{key}: "
          str << http_status(message)
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
