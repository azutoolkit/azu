require "../spec_helper"

describe "Azu Error Handling" do
  describe "ErrorContext" do
    it "creates error context with default values" do
      context = Azu::ErrorContext.new

      context.timestamp.should be_a(Time)
      context.request_id.should be_nil
      context.user_id.should be_nil
      context.session_id.should be_nil
      context.ip_address.should be_nil
      context.user_agent.should be_nil
      context.referer.should be_nil
      context.endpoint.should be_nil
      context.method.should be_nil
      context.params.should be_nil
      context.headers.should be_nil
      context.environment.should be_nil
    end

    it "creates error context from HTTP context" do
      request = HTTP::Request.new("GET", "/test?param=value")
      request.headers["User-Agent"] = "Test Browser"
      request.headers["Referer"] = "http://example.com"
      request.headers["X-Request-ID"] = "req-123"

      response = HTTP::Server::Response.new(IO::Memory.new)
      http_context = HTTP::Server::Context.new(request, response)

      context = Azu::ErrorContext.from_http_context(http_context)

      context.request_id.should eq("req-123")
      context.user_agent.should eq("Test Browser")
      context.referer.should eq("http://example.com")
      context.endpoint.should eq("/test")
      context.method.should eq("GET")
      context.params.should eq({"param" => "value"})
      context.headers.should eq(request.headers)
    end

    it "loads the process environment only when asked to" do
      response = HTTP::Server::Response.new(IO::Memory.new)
      http_context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), response)

      Azu::ErrorContext.from_http_context(http_context).environment.should be_nil
      Azu::ErrorContext.from_http_context(http_context, load_environment: true).environment.should_not be_nil
    end

    it "never puts secret environment values, URL passwords or credential headers in the debug context" do
      ENV["AZU_SPEC_SESSION_SECRET"] = "hunter2-secret"
      ENV["AZU_SPEC_DATABASE_URL"] = "postgres://app:hunter2-password@db.internal/app"
      ENV["AZU_SPEC_PLAIN"] = "visible"
      begin
        Azu::CachedEnvironment.refresh
        headers = HTTP::Headers{"Authorization" => "Bearer hunter2-bearer", "Cookie" => "session=hunter2-cookie", "X-CSRF-Token" => "hunter2-csrf", "Accept" => "text/html"}
        context = Azu::ErrorContext.new(headers: headers, params: {"api_key" => "hunter2-query", "page" => "2"}, _load_environment: true)

        [context.to_json, context.to_h.to_s].each do |dump|
          dump.should_not contain("hunter2")
          dump.should contain("[FILTERED]")
        end
        context.to_h["environment"].as(Hash(String, String))["AZU_SPEC_PLAIN"].should eq "visible"
        context.to_h["headers"].as(Hash(String, Array(String)))["Accept"].should eq ["text/html"]
        context.to_h["params"].as(Hash(String, String))["page"].should eq "2"
        context.headers.should eq headers # the request itself is untouched
      ensure
        %w[AZU_SPEC_SESSION_SECRET AZU_SPEC_DATABASE_URL AZU_SPEC_PLAIN].each { |name| ENV.delete(name) }
        Azu::CachedEnvironment.refresh
      end
    end

    it "redacts credentials in the referer, the endpoint and an old-style URL password" do
      context = Azu::ErrorContext.new(referer: "https://a.example/x?token=hunter2&page=2", endpoint: "/cb?password=hunter2&next=/")

      [context.to_json, context.to_h.to_s].each do |dump|
        dump.should_not contain("hunter2")
        dump.should contain("page=2")
      end
      context.referer.should eq "https://a.example/x?token=hunter2&page=2"
    end

    it "redacts MYSQL_PWD and SESSION variables of the environment it carries" do
      ENV["MYSQL_PWD"] = "hunter2-mysql"
      ENV["SESSION_STORE_URL"] = "redis://u:hunter2-redis@cache/0"
      begin
        Azu::CachedEnvironment.refresh
        Azu::ErrorContext.new(_load_environment: true).to_json.should_not contain("hunter2")
      ensure
        ENV.delete("MYSQL_PWD")
        ENV.delete("SESSION_STORE_URL")
        Azu::CachedEnvironment.refresh
      end
    end

    it "gives the development exception page redacted query parameters, headers and cookies" do
      with_azu_env(Azu::Environment::Development) do
        request = HTTP::Request.new("GET", "/boom?token=hunter2&page=2")
        response = HTTP::Server::Response.new(IO::Memory.new)
        response.cookies << HTTP::Cookie.new("session", "hunter2-cookie")
        response.headers["X-Api-Key-Id"] = "hunter2-header"
        html = Azu::Response::NotFound.new("/boom").html(HTTP::Server::Context.new(request, response))
        html.should contain("token")

        html.should_not contain("hunter2")
        html.should contain("page")
        html.should contain("[FILTERED]")
        html.should contain("2")
      end
    end

    it "converts to JSON" do
      context = Azu::ErrorContext.new(
        request_id: "req-123",
        endpoint: "/test",
        method: "GET"
      )

      json = context.to_json
      parsed = JSON.parse(json)

      parsed["request_id"].should eq("req-123")
      parsed["endpoint"].should eq("/test")
      parsed["method"].should eq("GET")
    end

    it "converts to hash" do
      context = Azu::ErrorContext.new(
        request_id: "req-123",
        endpoint: "/test"
      )

      hash = context.to_h

      hash["request_id"].should eq("req-123")
      hash["endpoint"].should eq("/test")
      hash["timestamp"].should be_a(String)
    end
  end

  describe "ErrorReport" do
    it "creates error report from exception" do
      exception = Exception.new("Test error")
      context = Azu::ErrorContext.new(request_id: "req-123")

      report = Azu::ErrorReport.new(exception, context)

      report.error_type.should eq("Exception")
      report.message.should eq("Test error")
      report.context.should eq(context)
      report.severity.should eq(Azu::ErrorReporter::Severity::ERROR)
      report.id.should be_a(String)
      report.fingerprint.should be_a(String)
    end

    it "generates unique fingerprint for similar errors" do
      exception1 = Exception.new("Test error")
      exception2 = Exception.new("Test error")

      report1 = Azu::ErrorReport.new(exception1)
      report2 = Azu::ErrorReport.new(exception2)

      report1.fingerprint.should eq(report2.fingerprint)
    end

    it "converts to JSON" do
      exception = Exception.new("Test error")
      report = Azu::ErrorReport.new(exception)

      json = report.to_json
      parsed = JSON.parse(json)

      parsed["error_type"].should eq("Exception")
      parsed["message"].should eq("Test error")
      parsed["severity"].should eq("ERROR")
    end
  end

  describe "ErrorReporter" do
    it "reports errors with different severities" do
      reporter = Azu::ErrorReporter.new
      exception = Exception.new("Test error")

      report = reporter.report(exception, severity: Azu::ErrorReporter::Severity::WARN)

      report.severity.should eq(Azu::ErrorReporter::Severity::WARN)
      reporter.get_recent_errors(1).first.should eq(report)
    end

    it "gets recent errors" do
      reporter = Azu::ErrorReporter.new
      exception1 = Exception.new("Error 1")
      exception2 = Exception.new("Error 2")

      reporter.report(exception1)
      reporter.report(exception2)

      recent = reporter.get_recent_errors(1)
      recent.size.should eq(1)
      recent.first.message.should eq("Error 2")
    end

    it "gets errors by type" do
      reporter = Azu::ErrorReporter.new
      exception1 = Exception.new("Error 1")
      exception2 = ArgumentError.new("Error 2")

      reporter.report(exception1)
      reporter.report(exception2)

      argument_errors = reporter.get_errors_by_type("ArgumentError")
      argument_errors.size.should eq(1)
      argument_errors.first.error_type.should eq("ArgumentError")
    end

    it "clears errors" do
      reporter = Azu::ErrorReporter.new
      exception = Exception.new("Test error")

      reporter.report(exception)
      reporter.get_recent_errors.size.should eq(1)

      reporter.clear_errors
      reporter.get_recent_errors.size.should eq(0)
    end
  end

  describe "Response::Error" do
    it "creates basic error" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::BAD_REQUEST, [] of String)

      error.title.should eq("Test error")
      error.detail.should eq("Test error")
      error.status.should eq(HTTP::Status::BAD_REQUEST)
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

      error = with_azu_env(Azu::Environment::Development) { Azu::Response::Error.from_exception(exception, 400, context) }

      error.title.should eq("Test exception")
      error.status.should eq(HTTP::Status::BAD_REQUEST)
      error.context.should eq(context)

      public_error = with_azu_env(Azu::Environment::Production) { Azu::Response::Error.from_exception(exception, 400, context) }
      public_error.title.should eq("Bad Request")
      public_error.detail.should eq("Bad Request")
    end

    it "generates HTML error page" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::BAD_REQUEST, [] of String)
      html = with_azu_env(Azu::Environment::Production) { error.html }

      html.should contain("Test error")
      html.should contain(error.error_id)
      # The public page leaves the fingerprint to the X-Error-Fingerprint header.
      html.should_not contain(error.fingerprint)
    end

    it "generates JSON error response" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::BAD_REQUEST, [] of String)
      json = error.json
      parsed = JSON.parse(json)

      parsed["title"].should eq("Test error")
      parsed["detail"].should eq("Test error")
      parsed["error_id"].should eq(error.error_id)
      parsed["type"].should eq("about:blank")
    end

    it "keeps the pre-0.6 JSON body behind error_format = Legacy" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::BAD_REQUEST, [] of String)
      original = Azu::CONFIG.error_format
      Azu::CONFIG.error_format = Azu::ErrorFormat::Legacy
      begin
        parsed = JSON.parse(error.json)
      ensure
        Azu::CONFIG.error_format = original
      end

      parsed["Title"].should eq("Test error")
      parsed["ErrorId"].should eq(error.error_id)
      parsed["Fingerprint"].should eq(error.fingerprint)
    end

    it "puts the request context in the legacy body in development only" do
      context = Azu::ErrorContext.new(request_id: "req-123", ip_address: "10.0.0.9", user_agent: "spec")
      error = Azu::Response::ValidationError.new({"name" => ["must be present"]}, context)
      original = Azu::CONFIG.error_format
      Azu::CONFIG.error_format = Azu::ErrorFormat::Legacy
      begin
        development = with_azu_env(Azu::Environment::Development) { JSON.parse(error.json) }
        development["Context"]["ip_address"].should eq "10.0.0.9"
        production = with_azu_env(Azu::Environment::Production) { JSON.parse(error.json) }
        production["Context"].raw.should be_nil
        production["FieldErrors"]["name"].should eq ["must be present"]
      ensure
        Azu::CONFIG.error_format = original
      end
    end

    it "generates XML error response" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::BAD_REQUEST, [] of String)
      xml = error.xml

      xml.should contain("<error")
      xml.should contain("Test error")
      xml.should contain(error.error_id)
      xml.should contain(error.fingerprint)
    end

    it "generates text error response" do
      error = Azu::Response::Error.new("Test error", HTTP::Status::BAD_REQUEST, [] of String)
      text = error.text

      text.should contain("Status: 400")
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

    it "generates problem+json with field errors" do
      field_errors = {"email" => ["is invalid"]}
      error = Azu::Response::ValidationError.new(field_errors)
      json = error.json
      parsed = JSON.parse(json)

      parsed["errors"]["email"].should eq(["is invalid"])
      parsed["status"].should eq 422
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
end
