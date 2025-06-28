require "../../src/azu"

# Example demonstrating the enhanced async logging system
class AsyncLoggingExample
  def self.run
    puts "🚀 Starting Async Logging Example"
    puts "=" * 50

    # Create async loggers for different components
    api_logger = Azu::AsyncLogging::AsyncLogger.new("api")
    db_logger = Azu::AsyncLogging::AsyncLogger.new("database")
    auth_logger = Azu::AsyncLogging::AsyncLogger.new("auth")

    # Simulate request processing with request ID
    request_id = "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(8)}"

    api_logger = api_logger.with_request_id(request_id)
    db_logger = db_logger.with_request_id(request_id)
    auth_logger = auth_logger.with_request_id(request_id)

    # Simulate API request processing
    simulate_api_request(api_logger, db_logger, auth_logger)

    # Simulate error reporting
    simulate_error_reporting()

    # Simulate batch processing
    simulate_batch_logging()

    puts "\n✅ Async Logging Example Completed"
    puts "Check the logs above to see the structured async logging in action!"
  end

  private def self.simulate_api_request(api_logger, db_logger, auth_logger)
    puts "\n📡 Simulating API Request Processing..."

    # Request start
    api_logger.info("API request started", {
      "endpoint"  => "/api/users/123",
      "method"    => "GET",
      "client_ip" => "192.168.1.100",
    })

    # Authentication
    auth_logger.info("Authenticating user", {
      "user_id"     => "123",
      "auth_method" => "jwt",
    })

    # Database operations
    db_logger.info("Executing database query", {
      "query"  => "SELECT * FROM users WHERE id = ?",
      "params" => "123",
    })

    # Simulate database delay
    sleep(0.1)

    # Database success
    db_logger.info("Database query completed", {
      "rows_returned" => "1",
      "duration_ms"   => "100",
    })

    # API response
    api_logger.info("API request completed", {
      "status_code"       => "200",
      "response_size"     => "1024",
      "total_duration_ms" => "150",
    })
  end

  private def self.simulate_error_reporting
    puts "\n⚠️  Simulating Error Reporting..."

    # Simulate different types of errors
    begin
      raise "Database connection timeout"
    rescue ex
      Azu::AsyncLogging::ErrorReporter.report_error(ex)

      logger = Azu::AsyncLogging::AsyncLogger.new("error_test")
      logger.error("Database connection failed", {
        "retry_count" => "3",
        "timeout_ms"  => "5000",
      }, ex)
    end

    begin
      raise "Validation error: Invalid email format"
    rescue ex
      logger = Azu::AsyncLogging::AsyncLogger.new("validation")
      logger.warn("Validation failed", {
        "field" => "email",
        "value" => "invalid-email",
        "rule"  => "email_format",
      })
    end
  end

  private def self.simulate_batch_logging
    puts "\n📦 Simulating Batch Logging..."

    logger = Azu::AsyncLogging::AsyncLogger.new("batch_test")

    # Generate multiple log entries quickly to demonstrate batching
    20.times do |i|
      logger.info("Batch log entry #{i}", {
        "batch_id"     => "batch_#{Time.utc.to_unix}",
        "entry_number" => i.to_s,
      })
    end

    # Simulate some errors in the batch
    5.times do |i|
      logger.warn("Batch warning #{i}", {
        "warning_type" => "performance",
        "threshold"    => "100ms",
      })
    end
  end
end

# Run the example
AsyncLoggingExample.run
