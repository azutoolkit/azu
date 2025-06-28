require "../../src/azu"

module ErrorDemo
  # Request structure for error demonstration
  struct ErrorDemoRequest
    include Azu::Request

    getter error_type : String = "success"

    def initialize(@error_type = "success")
    end
  end

  # Response structure for successful error demonstration
  struct ErrorDemoResponse
    include Azu::Response

    def initialize(@message : String)
    end

    def render
      {
        status:                "success",
        message:               @message,
        available_error_types: [
          "validation",
          "authentication",
          "authorization",
          "rate_limit",
          "database",
          "external_service",
          "timeout",
          "generic",
        ],
      }.to_json
    end
  end

  # Demonstration endpoint for showcasing enhanced error handling
  struct ErrorDemoEndpoint
    include Azu::Endpoint(ErrorDemoRequest, ErrorDemoResponse)

    get "/error-demo"
    post "/error-demo"

    def call : ErrorDemoResponse
      case error_demo_request.error_type
      when "validation"
        demonstrate_validation_error
      when "authentication"
        demonstrate_authentication_error
      when "authorization"
        demonstrate_authorization_error
      when "rate_limit"
        demonstrate_rate_limit_error
      when "database"
        demonstrate_database_error
      when "external_service"
        demonstrate_external_service_error
      when "timeout"
        demonstrate_timeout_error
      when "generic"
        demonstrate_generic_error
      else
        ErrorDemoResponse.new("success")
      end
    end

    private def demonstrate_validation_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_validation_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1"
      )

      field_errors = {
        "email"    => ["is required", "must be a valid email address"],
        "password" => ["must be at least 8 characters"],
        "age"      => ["must be a positive integer"],
      }

      validation_error = Azu::Response::ValidationError.new(field_errors, context)

      raise validation_error
    end

    private def demonstrate_authentication_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_auth_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1"
      )

      raise Azu::Response::AuthenticationError.new("Invalid API key provided", context)
    end

    private def demonstrate_authorization_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_authz_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1",
        user_id: "user_123"
      )

      raise Azu::Response::AuthorizationError.new("Insufficient permissions to access this resource", context)
    end

    private def demonstrate_rate_limit_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_rate_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1"
      )

      raise Azu::Response::RateLimitError.new(retry_after: 60, context: context)
    end

    private def demonstrate_database_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_db_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1"
      )

      raise Azu::Response::DatabaseError.new("Connection to database failed after 3 retries", context)
    end

    private def demonstrate_external_service_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_ext_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1"
      )

      raise Azu::Response::ExternalServiceError.new("PaymentService", "Payment gateway is temporarily unavailable", context)
    end

    private def demonstrate_timeout_error
      context = Azu::ErrorContext.new(
        request_id: "demo_req_timeout_001",
        endpoint: "/error-demo",
        method: "POST",
        ip_address: "127.0.0.1"
      )

      raise Azu::Response::TimeoutError.new("Request timed out after 30 seconds", context)
    end

    private def demonstrate_generic_error
      # This will be caught by the rescuer and automatically wrapped with context
      raise "This is a generic exception to demonstrate error context capture"
    end
  end
end
