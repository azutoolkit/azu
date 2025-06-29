require "http/server/handler"
require "../performance_metrics"

module Azu
  module Handler
    # Performance monitoring handler that tracks request metrics automatically
    # Integrates with the existing handler chain to provide transparent performance tracking
    class PerformanceMonitor
      include HTTP::Handler

      getter metrics : PerformanceMetrics
      getter log : ::Log

      # Initialize with optional custom metrics collector
      def initialize(@metrics : PerformanceMetrics = PerformanceMetrics.new, @log : ::Log = CONFIG.log)
      end

      def call(context : HTTP::Server::Context)
        return call_next(context) unless @metrics.enabled

        start_time = Time.monotonic
        memory_before = PerformanceMetrics.current_memory_usage
        request_id = context.request.headers["X-Request-ID"]? || generate_request_id

        # Add request ID to context for logging
        context.request.headers["X-Request-ID"] = request_id

        begin
          call_next(context)
        ensure
          end_time = Time.monotonic
          memory_after = PerformanceMetrics.current_memory_usage
          processing_time = (end_time - start_time).total_milliseconds

          endpoint_name = get_endpoint_name(context.request)

          @metrics.record_request(
            endpoint: endpoint_name,
            method: context.request.method,
            path: context.request.resource,
            processing_time: processing_time,
            memory_before: memory_before,
            memory_after: memory_after,
            status_code: context.response.status_code,
            request_id: request_id
          )

          # Log performance warning for slow requests
          if processing_time > slow_request_threshold
            @log.warn { "Slow request detected: #{endpoint_name} took #{processing_time}ms" }
          end

          # Log memory warning for high memory usage
          memory_delta = memory_after - memory_before
          if memory_delta > memory_threshold
            @log.warn { "High memory usage: #{endpoint_name} used #{(memory_delta / 1024.0 / 1024.0).round(2)}MB" }
          end
        end
      end

      # Get current performance metrics
      def stats(since : Time? = nil)
        @metrics.aggregate_stats(since)
      end

      # Get endpoint-specific statistics
      def endpoint_stats(endpoint : String, since : Time? = nil)
        @metrics.endpoint_stats(endpoint, since)
      end

      # Enable or disable monitoring
      def enabled=(value : Bool)
        @metrics.enabled = value
      end

      def enabled?
        @metrics.enabled
      end

      # Clear all collected metrics
      def clear_metrics
        @metrics.clear
      end

      # Export metrics as JSON
      def to_json(io : IO)
        @metrics.to_json(io)
      end

      # Get recent request metrics for debugging
      def recent_requests(limit : Int32 = 50)
        @metrics.recent_requests(limit)
      end

      # Generate beautiful terminal performance report with colors and formatting
      def log_beautiful_report(since : Time? = nil)
        puts generate_beautiful_report(since)
      end

      # Generate beautifully formatted performance report for terminal display
      def generate_beautiful_report(since : Time? = nil) : String
        stats = @metrics.aggregate_stats(since)

        String.build do |str|
          # Header with decorative border
          str << "\n"
          str << "╔" << "═" * 78 << "╗\n".colorize(:cyan)
          str << "  " << " " * 25 << "🚀 PERFORMANCE REPORT 🚀".colorize(:yellow).bold << "\n"
          str << "\n"

          # Time range
          str << "📊 ".colorize(:blue) << "Analysis Period: ".colorize(:white).bold
          str << "#{format_time(stats.start_time)}".colorize(:light_blue) << " → ".colorize(:dark_gray)
          str << "#{format_time(stats.end_time)}\n".colorize(:light_blue)
          duration = stats.end_time - stats.start_time
          str << "   Duration: ".colorize(:dark_gray) << "#{format_duration(duration)}\n".colorize(:light_gray)
          str << "\n"

          # Request metrics section
          str << "┌─ ".colorize(:cyan) << "REQUEST METRICS".colorize(:white).bold << " " << "─" * 50 << "\n".colorize(:cyan)

          # Total requests with visual indicator
          str << "  📈 Total Requests: ".colorize(:light_green).bold
          str << format_number(stats.total_requests).colorize(:green).bold
          str << " " << generate_bar(stats.total_requests, 100, 20).colorize(:green)
          str << "\n"

          # Error metrics
          error_color = stats.error_rate > 5.0 ? :red : stats.error_rate > 1.0 ? :yellow : :green
          str << "  ❌ Error Rate: ".colorize(:light_red).bold
          str << "#{stats.error_rate}%".colorize(error_color).bold
          str << " (#{stats.error_requests}/#{stats.total_requests})".colorize(:dark_gray)
          str << " " << generate_percentage_bar(stats.error_rate, 20).colorize(error_color)
          str << "\n\n"

          # Response time metrics
          str << "┌─ ".colorize(:magenta) << "RESPONSE TIME METRICS".colorize(:white).bold << " " << "─" * 42 << "\n".colorize(:magenta)

          # Average response time
          avg_color = response_time_color(stats.avg_response_time)
          str << "  ⏱️  Average: ".colorize(:light_blue).bold
          str << "#{stats.avg_response_time.round(2)}ms".colorize(avg_color).bold
          str << " " << generate_response_time_bar(stats.avg_response_time, 20).colorize(avg_color)
          str << "\n"

          # Min/Max response times
          str << "  🏃 Fastest: ".colorize(:green).bold
          str << "#{stats.min_response_time.round(2)}ms".colorize(:green)
          str << "   🐌 Slowest: ".colorize(:red).bold
          str << "#{stats.max_response_time.round(2)}ms".colorize(:red)
          str << "\n"

          # Percentiles
          p95_color = response_time_color(stats.p95_response_time)
          p99_color = response_time_color(stats.p99_response_time)
          str << "  📊 95th %ile: ".colorize(:light_cyan).bold
          str << "#{stats.p95_response_time.round(2)}ms".colorize(p95_color)
          str << "   99th %ile: ".colorize(:light_cyan).bold
          str << "#{stats.p99_response_time.round(2)}ms".colorize(p99_color)
          str << "\n\n"

          # Memory metrics
          str << "┌─ ".colorize(:yellow) << "MEMORY METRICS".colorize(:white).bold << " " << "─" * 48 << "\n".colorize(:yellow)

          memory_color = memory_usage_color(stats.avg_memory_usage)
          str << "  🧠 Average Usage: ".colorize(:light_magenta).bold
          str << "#{stats.avg_memory_usage.round(2)}MB".colorize(memory_color).bold
          str << " " << generate_memory_bar(stats.avg_memory_usage, 20).colorize(memory_color)
          str << "\n"

          peak_color = memory_usage_color(stats.peak_memory_usage)
          str << "  📈 Peak Usage: ".colorize(:light_red).bold
          str << "#{stats.peak_memory_usage.round(2)}MB".colorize(peak_color).bold
          str << " " << generate_memory_bar(stats.peak_memory_usage, 20).colorize(peak_color)
          str << "\n"

          total_mb = stats.total_memory_allocated / 1024.0 / 1024.0
          str << "  💾 Total Allocated: ".colorize(:light_green).bold
          str << "#{total_mb.round(2)}MB".colorize(:cyan).bold
          str << "\n\n"

          # Cache metrics section
          cache_stats = @metrics.cache_stats(since: since)
          str << "┌─ ".colorize(:green) << "CACHE METRICS".colorize(:white).bold << " " << "─" * 51 << "\n".colorize(:green)

          if cache_stats.empty?
            str << "  📭 No cache data available".colorize(:dark_gray)
            str << "\n"
          else
            # Cache hit rate
            hit_rate = cache_stats["hit_rate"]? || 0.0
            hit_color = hit_rate >= 80.0 ? :green : hit_rate >= 60.0 ? :yellow : :red
            str << "  🎯 Hit Rate: ".colorize(:light_green).bold
            str << "#{hit_rate.round(1)}%".colorize(hit_color).bold
            str << " " << generate_percentage_bar(hit_rate, 20).colorize(hit_color)
            str << "\n"

            # Total operations
            total_ops = cache_stats["total_operations"]? || 0.0
            str << "  📊 Total Operations: ".colorize(:light_blue).bold
            str << format_number(total_ops.to_i).colorize(:cyan).bold

            # Show operation breakdown
            if total_ops > 0
              get_ops = cache_stats["get_operations"]? || 0.0
              set_ops = cache_stats["set_operations"]? || 0.0
              del_ops = cache_stats["delete_operations"]? || 0.0

              str << "  (#{format_number(get_ops.to_i)} GET".colorize(:green)
              str << ", #{format_number(set_ops.to_i)} SET".colorize(:blue)
              str << ", #{format_number(del_ops.to_i)} DEL".colorize(:red)
              str << ")".colorize(:dark_gray)
            end
            str << "\n"

            # Cache performance
            avg_time = cache_stats["avg_processing_time"]? || 0.0
            cache_time_color = avg_time < 1.0 ? :green : avg_time < 5.0 ? :yellow : :red
            str << "  ⚡ Cache Avg Time: ".colorize(:light_yellow).bold
            str << "#{avg_time.round(2)}ms".colorize(cache_time_color).bold
            str << " " << generate_response_time_bar(avg_time, 15).colorize(cache_time_color)
            str << "\n"

            # Error rate
            cache_error_rate = cache_stats["error_rate"]? || 0.0
            cache_error_color = cache_error_rate < 1.0 ? :green : cache_error_rate < 5.0 ? :yellow : :red
            str << "  ❌ Cache Error Rate: ".colorize(:light_red).bold
            str << "#{cache_error_rate.round(1)}%".colorize(cache_error_color).bold
            str << " " << generate_percentage_bar(cache_error_rate, 15).colorize(cache_error_color)
            str << "\n"

            # Data metrics
            avg_value_size = cache_stats["avg_value_size_bytes"]? || 0.0
            total_data = cache_stats["total_data_written"]? || 0.0
            if avg_value_size > 0 || total_data > 0
              str << "  💾 Avg Value Size: ".colorize(:light_magenta).bold
              str << "#{format_bytes(avg_value_size.to_i)}".colorize(:magenta)
              if total_data > 0
                str << "  Total Written: ".colorize(:light_magenta)
                str << "#{format_bytes(total_data.to_i)}".colorize(:magenta)
              end
              str << "\n"
            end
          end

          str << "\n"

          # Top endpoints section
          str << "┌─ ".colorize(:light_blue) << "TOP ENDPOINTS".colorize(:white).bold << " " << "─" * 49 << "\n".colorize(:light_blue)

          endpoint_counts = Hash(String, Int32).new(0)
          @metrics.recent_requests(1000).each do |req|
            endpoint_counts[req.endpoint] += 1
          end

          if endpoint_counts.empty?
            str << "  📭 No endpoint data available".colorize(:dark_gray)
            str << "\n"
          else
            endpoint_counts.to_a.sort_by(&.[1]).reverse!.first(5).each_with_index do |endpoint_data, index|
              endpoint, count = endpoint_data
              endpoint_stats = @metrics.endpoint_stats(endpoint, since)
              avg_time = endpoint_stats["avg_response_time"]? || 0.0
              error_rate = endpoint_stats["error_rate"]? || 0.0

              # Truncate endpoint name if too long
              display_name = endpoint.size > 25 ? "#{endpoint[0..22]}..." : endpoint

              str << "  #{index + 1}. ".colorize(:white).bold
              str << "#{display_name}".colorize(:light_cyan).bold
              str << " " * (28 - display_name.size)
              str << "#{format_number(count)} reqs".colorize(:green)
              str << "\n"

              str << "     ⏱️ #{avg_time.round(1)}ms".colorize(response_time_color(avg_time))
              str << "  ❌ #{error_rate}%".colorize(error_rate > 1.0 ? :red : :green)
              str << "\n"
            end
          end

          str << "\n"

          # Footer
          str << "Generated at ".colorize(:dark_gray) << Time.local.to_s("%H:%M:%S").colorize(:light_gray)
          str << " | Monitoring: ".colorize(:dark_gray) << (@metrics.enabled ? "ENABLED ✓".colorize(:green) : "DISABLED ✗".colorize(:red))
          str << "\n\n"
        end
      end

      # Log performance summary in a compact beautiful format
      def log_summary_report(since : Time? = nil)
        stats = @metrics.aggregate_stats(since)

        summary = String.build do |str|
          str << "\n🚀 ".colorize(:yellow)
          str << "PERFORMANCE SUMMARY".colorize(:white).bold
          str << " | "
          str << "#{stats.total_requests} reqs".colorize(:cyan)
          str << " | "
          str << "#{stats.avg_response_time.round(1)}ms avg".colorize(response_time_color(stats.avg_response_time))
          str << " | "
          str << "#{stats.error_rate}% errors".colorize(stats.error_rate > 1.0 ? :red : :green)
          str << " | "
          str << "#{stats.avg_memory_usage.round(1)}MB mem".colorize(memory_usage_color(stats.avg_memory_usage))
          str << "\n"
        end

        puts summary
      end

      # Generate performance report
      def generate_report(since : Time? = nil) : String
        stats = @metrics.aggregate_stats(since)

        String.build do |str|
          str << "=== Performance Report ===\n"
          str << "Time Range: #{stats.start_time} to #{stats.end_time}\n"
          str << "Total Requests: #{stats.total_requests}\n"
          str << "Error Requests: #{stats.error_requests} (#{stats.error_rate}%)\n"
          str << "Average Response Time: #{stats.avg_response_time.round(2)}ms\n"
          str << "Min Response Time: #{stats.min_response_time.round(2)}ms\n"
          str << "Max Response Time: #{stats.max_response_time.round(2)}ms\n"
          str << "95th Percentile: #{stats.p95_response_time.round(2)}ms\n"
          str << "99th Percentile: #{stats.p99_response_time.round(2)}ms\n"
          str << "Average Memory Usage: #{stats.avg_memory_usage.round(2)}MB\n"
          str << "Peak Memory Usage: #{stats.peak_memory_usage.round(2)}MB\n"
          str << "Total Memory Allocated: #{(stats.total_memory_allocated / 1024.0 / 1024.0).round(2)}MB\n"

          # Add endpoint breakdown
          str << "\n=== Top Endpoints by Request Count ===\n"
          endpoint_counts = Hash(String, Int32).new(0)
          @metrics.recent_requests(1000).each do |req|
            endpoint_counts[req.endpoint] += 1
          end

          endpoint_counts.to_a.sort_by(&.[1]).reverse!.first(10).each do |endpoint, count|
            endpoint_stats = @metrics.endpoint_stats(endpoint, since)
            avg_time = endpoint_stats["avg_response_time"]? || 0.0
            error_rate = endpoint_stats["error_rate"]? || 0.0
            str << "#{endpoint}: #{count} requests, #{avg_time.round(2)}ms avg, #{error_rate}% errors\n"
          end
        end
      end

      private def get_endpoint_name(request : HTTP::Request) : String
        # Try to get endpoint name from header set by endpoint handler
        endpoint_name = request.headers["X-Azu-Endpoint"]?
        return endpoint_name if endpoint_name

        # Fallback to path-based name
        path = request.resource.split('?').first
        segments = path.split('/').reject(&.empty?)
        return "root" if segments.empty?

        # Create a normalized endpoint name
        segments.map do |segment|
          # Replace parameters with placeholder
          segment.starts_with?(':') ? ":param" : segment
        end.join("_")
      end

      private def generate_request_id : String
        Random::Secure.hex(8)
      end

      private def slow_request_threshold : Float64
        ENV.fetch("PERFORMANCE_SLOW_REQUEST_THRESHOLD", "1000").to_f
      end

      private def memory_threshold : Int64
        ENV.fetch("PERFORMANCE_MEMORY_THRESHOLD", "10485760").to_i64 # 10MB
      end

      # Helper methods for beautiful formatting

      private def format_time(time : Time) : String
        time.to_s("%H:%M:%S")
      end

      private def format_duration(span : Time::Span) : String
        if span.total_hours >= 1
          "#{span.total_hours.round(1)}h"
        elsif span.total_minutes >= 1
          "#{span.total_minutes.round(1)}m"
        else
          "#{span.total_seconds.round(1)}s"
        end
      end

      private def format_number(num : Int32) : String
        if num >= 1_000_000
          "#{(num / 1_000_000.0).round(1)}M"
        elsif num >= 1_000
          "#{(num / 1_000.0).round(1)}K"
        else
          num.to_s
        end
      end

      private def format_bytes(bytes : Int32) : String
        if bytes >= 1_048_576 # 1MB
          "#{(bytes / 1_048_576.0).round(1)}MB"
        elsif bytes >= 1_024 # 1KB
          "#{(bytes / 1_024.0).round(1)}KB"
        else
          "#{bytes}B"
        end
      end

      private def response_time_color(time_ms : Float64) : Symbol
        case time_ms
        when 0..50     then :green
        when 50..200   then :light_green
        when 200..500  then :yellow
        when 500..1000 then :light_red
        else                :red
        end
      end

      private def memory_usage_color(usage_mb : Float64) : Symbol
        case usage_mb
        when 0..1   then :green
        when 1..5   then :light_green
        when 5..20  then :yellow
        when 20..50 then :light_red
        else             :red
        end
      end

      private def generate_bar(value : Int32, max_value : Int32, width : Int32) : String
        return "─" * width if max_value <= 0
        filled = ((value.to_f / max_value) * width).to_i
        "█" * filled + "░" * (width - filled)
      end

      private def generate_percentage_bar(percentage : Float64, width : Int32) : String
        filled = ((percentage / 100.0) * width).to_i
        "█" * filled + "░" * (width - filled)
      end

      private def generate_response_time_bar(time_ms : Float64, width : Int32) : String
        # Scale bar based on reasonable response time ranges
        max_time = 1000.0 # 1 second max for bar scale
        normalized = [time_ms / max_time, 1.0].min
        filled = (normalized * width).to_i
        "█" * filled + "░" * (width - filled)
      end

      private def generate_memory_bar(usage_mb : Float64, width : Int32) : String
        # Scale bar based on reasonable memory usage ranges
        max_memory = 100.0 # 100MB max for bar scale
        normalized = [usage_mb / max_memory, 1.0].min
        filled = (normalized * width).to_i
        "█" * filled + "░" * (width - filled)
      end
    end
  end
end
