require "../../src/azu"

# Demonstration of the refactored performance reporting system
# This shows how SOLID principles make the code more flexible and extensible

module PerformanceReporterDemo
  def self.demonstrate_solid_principles
    puts "\n🚀 Performance Reporter Refactoring Demo".colorize(:yellow).bold
    puts "=" * 60

    # Create the service that orchestrates reporting
    service = Azu::PerformanceReportService.new

    puts "\n1. Using LogPerformanceReporter (Beautiful Terminal Output)".colorize(:green).bold
    puts "-" * 60
    service.log_beautiful_report

    puts "\n2. Using JsonPerformanceReporter (Structured Data)".colorize(:green).bold
    puts "-" * 60
    json_report = service.generate_json_report
    puts json_report

    puts "\n3. Monitoring Control (Separated Responsibility)".colorize(:green).bold
    puts "-" * 60
    puts "Current monitoring status: #{Azu::PerformanceMonitoringManager.enabled?}"

    puts "\n4. Different Output Formats for Health Check".colorize(:green).bold
    puts "-" * 60
    puts "Log Format:"
    service.log_health_check
    puts "\nJSON Format:"
    puts service.generate_json_health_check

    puts "\n5. Time-based Reports".colorize(:green).bold
    puts "-" * 60
    puts "JSON Hourly Report:"
    puts service.generate_json_hourly_report

    demonstrate_extensibility
  end

  def self.demonstrate_extensibility
    puts "\n6. Extensibility Demo - Custom Reporter".colorize(:green).bold
    puts "-" * 60

    # Create a custom CSV reporter (extending the system)
    csv_reporter = CsvPerformanceReporter.new
    csv_report = csv_reporter.generate_report
    puts "CSV Format:"
    puts csv_report

    puts "\n7. Periodic Reporting with Different Formats".colorize(:green).bold
    puts "-" * 60
    service = Azu::PerformanceReportService.new

    # Start periodic reporting in different formats
    puts "Starting periodic reporting in log format..."
    service.start_periodic_reporting(:log, 5.seconds)

    puts "Starting periodic reporting in JSON format..."
    service.start_periodic_reporting(:json, 10.seconds)

    # Let it run for a bit then stop
    sleep(2)
    puts "Demo periodic reporting started (would run in background)"
  end

  # Example of how easy it is to extend the system (Open/Closed Principle)
  class CsvPerformanceReporter < Azu::PerformanceReporter
    def format_report(stats, since : Time?) : String
      csv_lines = [] of String
      csv_lines << "timestamp,total_requests,avg_response_time_ms,error_rate_percent,requests_per_second,memory_usage_mb"

      timestamp = Time.utc.to_s
      memory_mb = (Azu::PerformanceMetrics.current_memory_usage / 1024.0 / 1024.0).round(2)

      csv_lines << "#{timestamp},#{stats.total_requests},#{stats.avg_response_time.round(2)},#{stats.error_rate.round(2)},#{stats.requests_per_second.round(2)},#{memory_mb}"

      csv_lines.join("\n")
    end

    def unavailable_message : String
      "timestamp,error\n#{Time.utc},Performance monitoring is not enabled"
    end

    def output(content : String) : Nil
      puts content
    end
  end

  # Example of a file-based reporter (demonstrating different output mechanisms)
  class FilePerformanceReporter < Azu::PerformanceReporter
    def initialize(@file_path : String)
    end

    def format_report(stats, since : Time?) : String
      # Reuse JSON formatting
      json_reporter = Azu::JsonPerformanceReporter.new
      json_reporter.format_report(stats, since)
    end

    def unavailable_message : String
      {error: "Performance monitoring is not enabled", timestamp: Time.utc.to_s}.to_json
    end

    def output(content : String) : Nil
      File.write(@file_path, content)
      puts "Report written to #{@file_path}".colorize(:green)
    end
  end

  def self.demonstrate_file_output
    puts "\n8. File Output Demo".colorize(:green).bold
    puts "-" * 60

    file_reporter = FilePerformanceReporter.new("/tmp/azu_performance_report.json")
    file_reporter.output_report
  end

  def self.show_benefits
    puts "\n✨ Benefits of SOLID Refactoring:".colorize(:cyan).bold
    benefits_text = <<-BENEFITS
    ✅ Single Responsibility Principle:
       - LogPerformanceReporter: handles log formatting
       - JsonPerformanceReporter: handles JSON formatting
       - PerformanceMonitoringManager: handles monitoring control
       - PerformanceReportScheduler: handles periodic reporting

    ✅ Open/Closed Principle:
       - Easy to add new reporters (CSV, XML, etc.) without modifying existing code
       - New output mechanisms (file, HTTP, database) can be added easily

    ✅ Liskov Substitution Principle:
       - Any PerformanceReporter can be used interchangeably
       - Schedulers work with any reporter type

    ✅ Interface Segregation Principle:
       - Clean, focused interfaces for each responsibility
       - Clients only depend on what they need

    ✅ Dependency Inversion Principle:
       - Service depends on abstractions, not concrete implementations
       - Easy to test and mock different components
    BENEFITS

    puts benefits_text.colorize(:light_cyan)
  end
end

# Run the demo if this file is executed directly
if PROGRAM_NAME.includes?("performance_reporter_demo")
  PerformanceReporterDemo.demonstrate_solid_principles
  PerformanceReporterDemo.demonstrate_file_output
  PerformanceReporterDemo.show_benefits
end
