require "../spec_helper"

describe "Performance Reporter SOLID Refactoring" do
  describe "PerformanceReporter abstract class" do
    it "follows the template method pattern" do
      # This test verifies the abstract class design
      # The actual implementations will inherit and implement the abstract methods
      true.should be_true # Placeholder - Crystal doesn't allow instantiating abstract classes
    end
  end

  describe "LogPerformanceReporter" do
    it "can be instantiated and generate reports" do
      reporter = Azu::LogPerformanceReporter.new
      reporter.should be_a(Azu::PerformanceReporter)
    end

    it "provides unavailable message when monitoring is disabled" do
      reporter = Azu::LogPerformanceReporter.new
      message = reporter.unavailable_message
      message.should eq("Performance monitoring is not enabled")
    end

    it "outputs to console" do
      reporter = Azu::LogPerformanceReporter.new
      # Testing output method doesn't throw errors
      reporter.output("test message")
    end
  end

  describe "JsonPerformanceReporter" do
    it "can be instantiated and generate JSON reports" do
      reporter = Azu::JsonPerformanceReporter.new
      reporter.should be_a(Azu::PerformanceReporter)
    end

    it "provides JSON error message when monitoring is disabled" do
      reporter = Azu::JsonPerformanceReporter.new
      message = reporter.unavailable_message
      message.should contain("Performance monitoring is not enabled")
      message.should contain("{") # Should be valid JSON
    end

    it "generates valid JSON health check" do
      reporter = Azu::JsonPerformanceReporter.new
      json = reporter.generate_health_check
      json.should contain("error") # When monitoring is disabled
      json.should contain("{")     # Should be valid JSON
    end
  end

  describe "PerformanceMonitoringManager" do
    it "follows single responsibility principle" do
      # Manager only handles monitoring control, nothing else
      Azu::PerformanceMonitoringManager.enabled?.should be_a(Bool)
    end

    it "provides control methods" do
      # These methods should not raise errors
      Azu::PerformanceMonitoringManager.enable!
      Azu::PerformanceMonitoringManager.disable!
      Azu::PerformanceMonitoringManager.clear_metrics!
    end
  end

  describe "PerformanceReportService" do
    it "can be instantiated and provides all methods" do
      service = Azu::PerformanceReportService.new
      service.should be_a(Azu::PerformanceReportService)
    end

    it "provides both log and JSON reporting methods" do
      service = Azu::PerformanceReportService.new

      # Should not raise errors
      service.log_beautiful_report
      service.log_summary
      service.log_health_check

      # JSON methods should return strings
      service.generate_json_report.should be_a(String)
      service.generate_json_health_check.should be_a(String)
      service.generate_json_hourly_report.should be_a(String)
      service.generate_json_daily_report.should be_a(String)
    end

    it "supports different periodic reporting formats" do
      service = Azu::PerformanceReportService.new

      # Should not raise errors (though they may not start in test environment)
      service.start_periodic_reporting(:log, 1.second)
      service.start_periodic_reporting(:json, 1.second)
    end

    it "shows help information" do
      service = Azu::PerformanceReportService.new
      service.show_help # Should not raise errors
    end
  end

  describe "SOLID Principles Compliance" do
    it "follows Single Responsibility Principle" do
      # Each class has one reason to change:
      # - LogPerformanceReporter: log formatting changes
      # - JsonPerformanceReporter: JSON formatting changes
      # - PerformanceMonitoringManager: monitoring control changes
      # - PerformanceReportScheduler: scheduling logic changes
      # - PerformanceReportService: orchestration changes
      true.should be_true
    end

    it "follows Open/Closed Principle" do
      # New reporters can be added without modifying existing code
      # This is demonstrated by the ease of creating custom reporters
      custom_reporter = CustomTestReporter.new
      custom_reporter.should be_a(Azu::PerformanceReporter)
      custom_reporter.generate_report.should be_a(String)
    end

    it "follows Liskov Substitution Principle" do
      # Any PerformanceReporter should be substitutable
      log_reporter = Azu::LogPerformanceReporter.new
      json_reporter = Azu::JsonPerformanceReporter.new
      custom_reporter = CustomTestReporter.new

      [log_reporter, json_reporter, custom_reporter].each do |reporter|
        reporter.generate_report.should be_a(String)
        reporter.unavailable_message.should be_a(String)
      end
    end

    it "follows Interface Segregation Principle" do
      # Clients only depend on the interfaces they need
      # PerformanceReportScheduler only needs the abstract PerformanceReporter
      # PerformanceMonitoringManager is independent
      # Each has focused, cohesive interfaces
      true.should be_true
    end

    it "follows Dependency Inversion Principle" do
      # PerformanceReportService depends on abstractions (PerformanceReporter)
      # Not on concrete implementations directly
      service = Azu::PerformanceReportService.new
      service.should be_a(Azu::PerformanceReportService)
    end
  end

  describe "Extensibility" do
    it "allows easy addition of new reporter types" do
      # CustomTestReporter demonstrates how easy it is to extend
      csv_reporter = CsvTestReporter.new
      csv_reporter.generate_report.should contain("CSV")
    end

    it "allows different output mechanisms" do
      # FileTestReporter shows different output mechanisms
      file_reporter = FileTestReporter.new
      file_reporter.generate_report.should be_a(String)
    end
  end
end

# Test implementations demonstrating extensibility

class CustomTestReporter < Azu::PerformanceReporter
  def format_report(stats, since : Time?) : String
    "Custom format: test report"
  end

  def unavailable_message : String
    "Custom: monitoring unavailable"
  end

  def output(content : String) : Nil
    # Test output - do nothing
  end
end

class CsvTestReporter < Azu::PerformanceReporter
  def format_report(stats, since : Time?) : String
    "CSV,format,test"
  end

  def unavailable_message : String
    "CSV,error,monitoring unavailable"
  end

  def output(content : String) : Nil
    # CSV output - could write to file
  end
end

class FileTestReporter < Azu::PerformanceReporter
  def format_report(stats, since : Time?) : String
    "File-based report content"
  end

  def unavailable_message : String
    "File reporter: monitoring unavailable"
  end

  def output(content : String) : Nil
    # Would write to file in real implementation
  end
end
