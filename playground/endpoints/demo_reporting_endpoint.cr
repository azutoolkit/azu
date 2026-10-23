require "../requests/empty_request"
require "../responses/generic_json_response"

module ExampleApp
  struct DemoReportingEndpoint
    include Azu::Action(EmptyRequest, GenericJsonResponse)

    get "/demo/reporting/:action"

    def call : GenericJsonResponse
      action = params.path["action"]? || "help"

      # Create the reporting service
      service = Azu::PerformanceReportService.new

      case action
      when "help"
        puts "\n🔧 Performance Reporting Help:".colorize(:cyan).bold
        service.show_help
        GenericJsonResponse.new({message: "Performance reporting help displayed in terminal ✓"})
      when "health"
        puts "\n💚 Health Check:".colorize(:green).bold
        service.log_health_check
        GenericJsonResponse.new({message: "Health check displayed in terminal ✓"})
      when "summary"
        puts "\n📊 Performance Summary:".colorize(:yellow).bold
        service.log_summary
        GenericJsonResponse.new({message: "Performance summary displayed in terminal ✓"})
      when "full"
        puts "\n🌈 Full Performance Report:".colorize(:magenta).bold
        service.log_beautiful_report
        GenericJsonResponse.new({message: "Full performance report displayed in terminal ✓"})
      when "hourly"
        puts "\n📅 Hourly Performance Report:".colorize(:blue).bold
        service.log_hourly_report
        GenericJsonResponse.new({message: "Hourly performance report displayed in terminal ✓"})
      when "daily"
        puts "\n📆 Daily Performance Report:".colorize(:blue).bold
        service.log_daily_report
        GenericJsonResponse.new({message: "Daily performance report displayed in terminal ✓"})
      when "enable"
        puts "\n🟢 Enabling Performance Monitoring:".colorize(:green).bold
        Azu::PerformanceMonitoringManager.enable!
        GenericJsonResponse.new({message: "Performance monitoring enabled ✓"})
      when "disable"
        puts "\n🟡 Disabling Performance Monitoring:".colorize(:yellow).bold
        Azu::PerformanceMonitoringManager.disable!
        GenericJsonResponse.new({message: "Performance monitoring disabled ✓"})
      when "clear"
        puts "\n🗑️ Clearing Performance Metrics:".colorize(:red).bold
        Azu::PerformanceMonitoringManager.clear_metrics!
        GenericJsonResponse.new({message: "Performance metrics cleared ✓"})
      when "start_periodic"
        puts "\n⏰ Starting Periodic Reporting:".colorize(:cyan).bold
        service.start_periodic_reporting(:log, 30.seconds)
        GenericJsonResponse.new({message: "Periodic reporting started (30 second intervals) ✓"})
      when "json_report"
        puts "\n📄 JSON Performance Report:".colorize(:cyan).bold
        json_data = service.generate_json_report
        puts json_data
        GenericJsonResponse.new({message: "JSON performance report displayed in terminal ✓", data: json_data})
      when "json_health"
        puts "\n📄 JSON Health Check:".colorize(:cyan).bold
        json_data = service.generate_json_health_check
        puts json_data
        GenericJsonResponse.new({message: "JSON health check displayed in terminal ✓", data: json_data})
      else
        available_actions = [
          "help", "health", "summary", "full", "hourly", "daily",
          "enable", "disable", "clear", "start_periodic",
          "json_report", "json_health",
        ]

        GenericJsonResponse.new({
          error:             "Unknown action: #{action}",
          available_actions: available_actions,
        })
      end
    end
  end
end
