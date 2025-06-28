require "colorize"
require "http/server/handler"
require "../log_format"

module Azu
  module Handler
    class SimpleLogger
      include HTTP::Handler

      getter log : ::Log
      getter async_logger : AsyncLogging::AsyncLogger

      def initialize(@log : ::Log = CONFIG.log)
        @async_logger = AsyncLogging::AsyncLogger.new("azu.http")
      end

      def call(context : HTTP::Server::Context)
        start_time = Time.monotonic
        request_id = generate_request_id(context)

        # Add request ID to context for tracing
        context.request.headers["X-Request-ID"] = request_id

        # Create async logger with request ID
        request_logger = @async_logger.with_request_id(request_id)

        begin
          call_next(context)
        rescue ex
          # Report error asynchronously
          AsyncLogging::ErrorReporter.report_error(ex)

          # Log error with context
          request_logger.error(
            "Request failed",
            build_request_context(context, Time.monotonic - start_time),
            ex
          )
          raise ex
        ensure
          # Log request completion asynchronously
          spawn(name: "http-request-logger") do
            log_request_completion(context, request_logger, start_time)
          end
        end

        context
      end

      private def log_request_completion(context : HTTP::Server::Context, logger : AsyncLogging::AsyncLogger, start_time : Time::Span)
        elapsed = Time.monotonic - start_time
        context_data = build_request_context(context, elapsed)

        case context.response.status_code
        when 200..299
          logger.info("HTTP Request completed", context_data)
        when 300..399
          logger.info("HTTP Request redirected", context_data)
        when 400..499
          logger.warn("HTTP Request client error", context_data)
        when 500..599
          logger.error("HTTP Request server error", context_data)
        else
          logger.warn("HTTP Request unknown status", context_data)
        end
      end

      private def build_request_context(context : HTTP::Server::Context, elapsed : Time::Span) : Hash(String, String)
        {
          "method" => context.request.method,
          "path" => context.request.resource,
          "endpoint" => get_endpoint_class_name(context),
          "status" => context.response.status_code.to_s,
          "latency" => format_latency(elapsed),
          "remote_addr" => get_remote_address(context),
          "user_agent" => context.request.headers["User-Agent"]? || "unknown",
          "content_length" => context.response.headers["Content-Length"]? || "0"
        }
      end

      private def get_endpoint_class_name(context : HTTP::Server::Context) : String
        context.request.headers["X-Azu-Endpoint"]? || "unknown"
      end

      private def get_remote_address(context : HTTP::Server::Context) : String
        case remote_address = context.request.remote_address
        when nil
          "-"
        when Socket::IPAddress
          remote_address.address
        else
          remote_address.to_s
        end
      end

      private def format_latency(elapsed : Time::Span) : String
        millis = elapsed.total_milliseconds
        return "#{millis.round(2)}ms" if millis >= 1
        "#{(millis * 1000).round(2)}µs"
      end

      private def generate_request_id(context : HTTP::Server::Context) : String
        # Use existing request ID if present
        if existing_id = context.request.headers["X-Request-ID"]?
          return existing_id
        end

        # Generate new request ID
        "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(8)}"
      end

      # Legacy method for backward compatibility
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
