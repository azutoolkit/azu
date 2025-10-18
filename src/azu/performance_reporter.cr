require "./handler/performance_monitor"
require "json"

module Azu
  # Abstract base class for performance reporters following SRP and OCP
  abstract class PerformanceReporter
    # Template method pattern - defines the structure of report generation
    def generate_report(since : Time? = nil) : String
      unless monitor_available?
        return unavailable_message
      end

      monitor = CONFIG.performance_monitor
      return unavailable_message unless monitor
      stats = monitor.stats(since)
      format_report(stats, since)
    end

    # Abstract method to be implemented by concrete reporters
    abstract def format_report(stats, since : Time?)
    abstract def unavailable_message : String

    # Template method for outputting reports
    def output_report(since : Time? = nil) : Nil
      report = generate_report(since)
      output(report)
    end

    # Abstract method for output mechanism
    abstract def output(content : String) : Nil

    private def monitor_available? : Bool
      !CONFIG.performance_monitor.nil?
    end
  end

  # Concrete implementation for beautiful terminal logging
  class LogPerformanceReporter < PerformanceReporter
    def format_report(stats, since : Time?) : String
      monitor = CONFIG.performance_monitor
      return unavailable_message unless monitor
      monitor.generate_beautiful_report(since)
    end

    def unavailable_message : String
      "Performance monitoring is not enabled"
    end

    def output(content : String) : Nil
      puts content
    end

    # Specific methods for log reporter
    def log_summary(since : Time? = nil) : Nil
      unless monitor_available?
        puts unavailable_message.colorize(:red)
        return
      end

      monitor = CONFIG.performance_monitor
      return unless monitor
      monitor.log_summary_report(since)
    end

    def log_health_check : Nil
      unless monitor_available?
        puts "❌ Performance monitoring is disabled".colorize(:red)
        return
      end

      monitor = CONFIG.performance_monitor
      return unless monitor
      stats = monitor.stats
      current_memory = Azu::PerformanceMetrics.current_memory_usage / 1024.0 / 1024.0

      health = String.build do |str|
        str << "\n💚 ".colorize(:green) << "SYSTEM HEALTH CHECK".colorize(:white).bold << "\n"
        str << "Current Memory: ".colorize(:light_blue) << "#{current_memory.round(2)}MB".colorize(:cyan)
        str << " | Monitoring: ".colorize(:light_blue) << (monitor.enabled? ? "ACTIVE ✓".colorize(:green) : "INACTIVE ✗".colorize(:red))
        str << "\nRecent Activity: ".colorize(:light_blue) << "#{stats.total_requests} requests".colorize(:cyan)

        if stats.total_requests > 0
          str << " | Avg: ".colorize(:light_blue) << "#{stats.avg_response_time.round(1)}ms".colorize(:cyan)
          str << " | Errors: ".colorize(:light_blue) << "#{stats.error_rate}%".colorize(stats.error_rate > 1.0 ? :red : :green)
        end
        str << "\n"
      end

      puts health
    end

    def log_hourly_report : Nil
      one_hour_ago = Time.utc - 1.hour
      puts "\n" + "=" * 80
      puts "📊 HOURLY PERFORMANCE REPORT".colorize(:yellow).bold
      puts "=" * 80
      output_report(one_hour_ago)
    end

    def log_daily_report : Nil
      one_day_ago = Time.utc - 1.day
      puts "\n" + "=" * 80
      puts "📅 DAILY PERFORMANCE REPORT".colorize(:yellow).bold
      puts "=" * 80
      output_report(one_day_ago)
    end
  end

  # Concrete implementation for JSON reporting
  class JsonPerformanceReporter < PerformanceReporter
    def format_report(stats, since : Time?) : String
      # Calculate requests per second
      duration_seconds = (stats.end_time - stats.start_time).total_seconds
      requests_per_second = duration_seconds > 0 ? (stats.total_requests / duration_seconds).round(2) : 0.0

      # Get cache statistics
      monitor = CONFIG.performance_monitor
      cache_stats = monitor ? monitor.metrics.cache_stats(since: since) : {} of String => Float64

      report_data = {
        timestamp:   Time.utc.to_s,
        since:       since ? since.to_s : nil,
        performance: {
          total_requests:       stats.total_requests,
          avg_response_time_ms: stats.avg_response_time.round(2),
          error_rate_percent:   stats.error_rate.round(2),
          requests_per_second:  requests_per_second,
          memory_usage_mb:      (Azu::PerformanceMetrics.current_memory_usage / 1024.0 / 1024.0).round(2),
        },
        cache: {
          hit_rate_percent:         cache_stats["hit_rate"]?.try(&.round(2)) || 0.0,
          total_operations:         cache_stats["total_operations"]?.try(&.to_i) || 0,
          get_operations:           cache_stats["get_operations"]?.try(&.to_i) || 0,
          set_operations:           cache_stats["set_operations"]?.try(&.to_i) || 0,
          delete_operations:        cache_stats["delete_operations"]?.try(&.to_i) || 0,
          error_rate_percent:       cache_stats["error_rate"]?.try(&.round(2)) || 0.0,
          avg_processing_time_ms:   cache_stats["avg_processing_time"]?.try(&.round(2)) || 0.0,
          avg_value_size_bytes:     cache_stats["avg_value_size_bytes"]?.try(&.to_i) || 0,
          total_data_written_bytes: cache_stats["total_data_written"]?.try(&.to_i) || 0,
        },
      }

      if monitor = CONFIG.performance_monitor
        report_data = report_data.merge({
          monitoring: {
            enabled:          monitor.enabled?,
            duration_minutes: since ? ((Time.utc - since).total_minutes.round(2)) : nil,
          },
        })
      end

      report_data.to_json
    end

    def unavailable_message : String
      {error: "Performance monitoring is not enabled"}.to_json
    end

    def output(content : String) : Nil
      puts content
    end

    # JSON-specific methods
    def generate_health_check : String
      unless monitor_available?
        return {error: "Performance monitoring is disabled"}.to_json
      end

      monitor = CONFIG.performance_monitor
      return {error: "Performance monitoring is disabled"}.to_json unless monitor
      stats = monitor.stats
      current_memory = Azu::PerformanceMetrics.current_memory_usage / 1024.0 / 1024.0

      {
        status:             "healthy",
        timestamp:          Time.utc.to_s,
        memory_usage_mb:    current_memory.round(2),
        monitoring_enabled: monitor.enabled?,
        recent_activity:    {
          total_requests:       stats.total_requests,
          avg_response_time_ms: stats.total_requests > 0 ? stats.avg_response_time.round(1) : 0,
          error_rate_percent:   stats.error_rate.round(2),
        },
      }.to_json
    end

    def generate_hourly_report : String
      one_hour_ago = Time.utc - 1.hour
      generate_report(one_hour_ago)
    end

    def generate_daily_report : String
      one_day_ago = Time.utc - 1.day
      generate_report(one_day_ago)
    end
  end

  # Monitoring control following SRP
  class PerformanceMonitoringManager
    def self.enable! : Nil
      if monitor = CONFIG.performance_monitor
        monitor.enabled = true
        puts "✅ Performance monitoring ENABLED".colorize(:green).bold
      end
    end

    def self.disable! : Nil
      if monitor = CONFIG.performance_monitor
        monitor.enabled = false
        puts "⏸️  Performance monitoring DISABLED".colorize(:yellow).bold
      end
    end

    def self.clear_metrics! : Nil
      if monitor = CONFIG.performance_monitor
        monitor.clear_metrics
        puts "\n🗑️  Performance metrics cleared".colorize(:yellow).bold
      end
    end

    def self.enabled? : Bool
      if monitor = CONFIG.performance_monitor
        monitor.enabled?
      else
        false
      end
    end
  end

  # Periodic reporting scheduler following SRP
  class PerformanceReportScheduler
    def self.start_periodic_reporting(
      reporter : PerformanceReporter,
      interval : Time::Span = 60.seconds,
    ) : Nil
      return unless CONFIG.env.development?

      spawn(name: "performance-reporter") do
        loop do
          sleep interval
          begin
            reporter.output_report
          rescue ex
            Log.for("Azu::PerformanceReportScheduler").error(exception: ex) {
              "Failed to generate performance report"
            }
          end
        end
      end
    end
  end

  # Service class to orchestrate the reporting system
  class PerformanceReportService
    @log_reporter : LogPerformanceReporter
    @json_reporter : JsonPerformanceReporter

    def initialize
      @log_reporter = LogPerformanceReporter.new
      @json_reporter = JsonPerformanceReporter.new
    end

    # Delegation methods for backward compatibility and convenience
    def log_beautiful_report(since : Time? = nil) : Nil
      @log_reporter.output_report(since)
    end

    def log_summary(since : Time? = nil) : Nil
      @log_reporter.log_summary(since)
    end

    def log_health_check : Nil
      @log_reporter.log_health_check
    end

    def log_hourly_report : Nil
      @log_reporter.log_hourly_report
    end

    def log_daily_report : Nil
      @log_reporter.log_daily_report
    end

    # JSON report methods
    def generate_json_report(since : Time? = nil) : String
      @json_reporter.generate_report(since)
    end

    def generate_json_health_check : String
      @json_reporter.generate_health_check
    end

    def generate_json_hourly_report : String
      @json_reporter.generate_hourly_report
    end

    def generate_json_daily_report : String
      @json_reporter.generate_daily_report
    end

    # Start periodic reporting with specified reporter type
    def start_periodic_reporting(
      format : Symbol = :log,
      interval : Time::Span = 60.seconds,
    ) : Nil
      reporter = case format
                 when :json then @json_reporter
                 else            @log_reporter
                 end

      PerformanceReportScheduler.start_periodic_reporting(reporter, interval)
    end

    # Help system
    def show_help : Nil
      help_text = <<-HELP

      🚀 AZU PERFORMANCE REPORTER - Available Commands:

      Log Reports:
        service.log_beautiful_report                    # Full detailed report
        service.log_summary                            # Compact summary
        service.log_health_check                       # Current system health
        service.log_hourly_report                      # Last hour stats
        service.log_daily_report                       # Last day stats

      JSON Reports:
        service.generate_json_report                   # Get JSON report
        service.generate_json_health_check             # Get JSON health check
        service.generate_json_hourly_report            # Get JSON hourly report
        service.generate_json_daily_report             # Get JSON daily report

      Monitoring Control:
        Azu::PerformanceMonitoringManager.enable!     # Enable monitoring
        Azu::PerformanceMonitoringManager.disable!    # Disable monitoring
        Azu::PerformanceMonitoringManager.clear_metrics! # Clear all metrics

      Periodic Reporting:
        service.start_periodic_reporting(:log, 30.seconds)   # Log format
        service.start_periodic_reporting(:json, 30.seconds)  # JSON format

      HELP

      puts help_text.colorize(:light_cyan)
    end
  end
end
