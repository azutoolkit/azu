require "../../src/azu"

module ExampleApp
  # Request contract for development tools operations
  struct DevelopmentToolsRequest
    include Azu::Request

    getter action : String

    def initialize(@action : String = "info")
    end

    # Initialize from JSON for POST requests
    def self.from_json(payload : String) : self
      data = JSON.parse(payload)
      action = data["action"]?.try(&.as_s) || "info"
      new(action)
    end

    # Initialize from query parameters for GET requests
    def self.from_query(query : String) : self
      params = URI::Params.parse(query)
      action = params["action"]? || "info"
      new(action)
    end

    def valid? : Bool
      valid_actions = ["info", "generate_test_data", "clear_metrics", "simulate_errors", "cache_test", "component_test"]
      valid_actions.includes?(@action)
    end

    def error_messages : Array(String)
      errors = [] of String
      unless valid?
        errors << "Invalid action: #{@action}. Valid actions are: info, generate_test_data, clear_metrics, simulate_errors, cache_test, component_test"
      end
      errors
    end
  end
end
