require "../../src/azu"

module ExampleApp
  # Response for development tools operations
  struct DevelopmentToolsResponse
    include Azu::Response

    getter message : String
    getter timestamp : String

    def initialize(@message : String)
      @timestamp = Time.utc.to_rfc3339
    end

    def render : String
      {
        message:           @message,
        timestamp:         @timestamp,
        dashboard_url:     "/dev-dashboard",
        available_actions: {
          "generate_test_data" => "Generate sample metrics data for dashboard",
          "clear_metrics"      => "Clear all performance metrics",
          "simulate_errors"    => "Generate sample error scenarios",
          "cache_test"         => "Run cache operation tests",
          "component_test"     => "Run component lifecycle tests",
        },
      }.to_json
    end
  end
end
