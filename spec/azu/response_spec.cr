require "../spec_helper"

describe Azu::Response do
  describe "Empty response" do
    it "creates empty response" do
      response = Azu::Response::Empty.new
      response.should be_a(Azu::Response)
    end

    it "renders empty response" do
      response = Azu::Response::Empty.new
      response.render.should be_nil
    end
  end

  describe "Error response" do
    it "creates basic error" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)

      error.title.should eq("Test error")
      error.detail.should eq("Test error")
      error.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
      error.error_id.should be_a(String)
      error.fingerprint.should be_a(String)
    end

    it "creates error with custom title and status" do
      error = Azu::Response::Error.new(
        "Custom Title",
        HTTP::Status::BAD_REQUEST,
        ["Error 1", "Error 2"]
      )

      error.title.should eq("Custom Title")
      error.status.should eq(HTTP::Status::BAD_REQUEST)
      error.errors.should eq(["Error 1", "Error 2"])
    end

    it "creates error from exception" do
      exception = Exception.new("Test exception")
      context = Azu::ErrorContext.new(request_id: "req-123")

      error = Azu::Response::Error.from_exception(exception, 400, context)

      error.title.should eq("Test exception")
      error.status.should eq(HTTP::Status::BAD_REQUEST)
      error.context.should eq(context)
    end

    it "generates unique fingerprint" do
      error1 = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      error2 = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)

      error1.fingerprint.should eq(error2.fingerprint)
      error1.error_id.should_not eq(error2.error_id)
    end

    it "provides link to HTTP status documentation" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      error.link.should contain("developer.mozilla.org")
      error.link.should contain("500")
    end
  end

  describe "Error rendering" do
    it "generates HTML error page" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      html = error.html

      html.should contain("Test error")
      html.should contain(error.error_id)
      html.should contain(error.fingerprint)
    end

    it "generates JSON error response" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      json = error.json
      parsed = JSON.parse(json)

      parsed["Title"].should eq("Test error")
      parsed["Detail"].should eq("Test error")
      parsed["ErrorId"].should eq(error.error_id)
      parsed["Fingerprint"].should eq(error.fingerprint)
    end

    it "generates XML error response" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      xml = error.xml

      xml.should contain("<error")
      xml.should contain("Test error")
      xml.should contain(error.error_id)
      xml.should contain(error.fingerprint)
    end

    it "generates text error response" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      text = error.text

      text.should contain("Status: 500")
      text.should contain("Test error")
      text.should contain(error.error_id)
      text.should contain(error.fingerprint)
    end
  end

  describe "ValidationError" do
    it "creates validation error with field errors" do
      field_errors = {"email" => ["is invalid"], "name" => ["is required"]}
      context = Azu::ErrorContext.new(request_id: "req-123")

      error = Azu::Response::ValidationError.new(field_errors, context)

      error.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      error.title.should eq("Validation Error")
      error.field_errors.should eq(field_errors)
      error.context.should eq(context)
    end

    it "creates validation error for single field" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::ValidationError.new("email", "is invalid", context)

      error.field_errors["email"].should eq(["is invalid"])
      error.context.should eq(context)
    end

    it "adds field errors" do
      error = Azu::Response::ValidationError.new("email", "is invalid")
      error.add_field_error("name", "is required")

      error.field_errors["email"].should eq(["is invalid"])
      error.field_errors["name"].should eq(["is required"])
    end

    it "generates JSON with field errors" do
      field_errors = {"email" => ["is invalid"]}
      error = Azu::Response::ValidationError.new(field_errors)
      json = error.json
      parsed = JSON.parse(json)

      parsed["FieldErrors"]["email"].should eq(["is invalid"])
    end
  end

  describe "AuthenticationError" do
    it "creates authentication error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::AuthenticationError.new("Login required", context)

      error.status.should eq(HTTP::Status::UNAUTHORIZED)
      error.title.should eq("Authentication Required")
      error.detail.should eq("Login required")
      error.context.should eq(context)
    end
  end

  describe "AuthorizationError" do
    it "creates authorization error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::AuthorizationError.new("Admin access required", context)

      error.status.should eq(HTTP::Status::FORBIDDEN)
      error.title.should eq("Authorization Failed")
      error.detail.should eq("Admin access required")
      error.context.should eq(context)
    end
  end

  describe "RateLimitError" do
    it "creates rate limit error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::RateLimitError.new(60, context)

      error.status.should eq(HTTP::Status::TOO_MANY_REQUESTS)
      error.title.should eq("Rate Limit Exceeded")
      error.retry_after.should eq(60)
      error.context.should eq(context)
    end

    it "creates rate limit error without retry after" do
      error = Azu::Response::RateLimitError.new

      error.retry_after.should be_nil
      error.detail.should contain("Rate limit exceeded")
    end
  end

  describe "DatabaseError" do
    it "creates database error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::DatabaseError.new("Connection failed", context)

      error.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
      error.title.should eq("Database Error")
      error.detail.should eq("Connection failed")
      error.context.should eq(context)
    end
  end

  describe "ExternalServiceError" do
    it "creates external service error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::ExternalServiceError.new("Payment API", "Service unavailable", context)

      error.status.should eq(HTTP::Status::BAD_GATEWAY)
      error.title.should eq("Payment API Service Error")
      error.detail.should eq("Service unavailable")
      error.service_name.should eq("Payment API")
      error.context.should eq(context)
    end

    it "creates external service error without service name" do
      error = Azu::Response::ExternalServiceError.new(message: "Service unavailable")

      error.title.should eq("External Service Error")
      error.service_name.should be_nil
    end
  end

  describe "TimeoutError" do
    it "creates timeout error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::TimeoutError.new("Request timed out", context)

      error.status.should eq(HTTP::Status::REQUEST_TIMEOUT)
      error.title.should eq("Request Timeout")
      error.detail.should eq("Request timed out")
      error.context.should eq(context)
    end
  end

  describe "Legacy error classes" do
    it "creates Forbidden error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::Forbidden.new(context)

      error.status.should eq(HTTP::Status::FORBIDDEN)
      error.title.should eq("Authorization Failed")
      error.context.should eq(context)
    end

    it "creates BadRequest error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::BadRequest.new("Invalid input", context)

      error.status.should eq(HTTP::Status::BAD_REQUEST)
      error.title.should eq("Bad Request")
      error.detail.should eq("Invalid input")
      error.context.should eq(context)
    end

    it "creates NotFound error" do
      context = Azu::ErrorContext.new(request_id: "req-123")
      error = Azu::Response::NotFound.new("/missing/path", context)

      error.status.should eq(HTTP::Status::NOT_FOUND)
      error.title.should eq("Not Found")
      error.source.should eq("/missing/path")
      error.context.should eq(context)
    end
  end

  describe "Error context handling" do
    it "includes context in XML output" do
      context = Azu::ErrorContext.new(
        request_id: "req-123",
        endpoint: "/test",
        method: "GET",
        ip_address: "127.0.0.1",
        user_agent: "Test Browser"
      )
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String, context)
      xml = error.xml

      xml.should contain("req-123")
      xml.should contain("/test")
      xml.should contain("GET")
      xml.should contain("127.0.0.1")
      xml.should contain("Test Browser")
    end

    it "includes context in text output" do
      context = Azu::ErrorContext.new(
        request_id: "req-123",
        endpoint: "/test",
        method: "GET"
      )
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String, context)
      text = error.text

      text.should contain("Request ID: req-123")
      text.should contain("Endpoint: GET /test")
    end

    it "handles nil context gracefully" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      text = error.text

      text.should contain("Context: None")
    end
  end
end
