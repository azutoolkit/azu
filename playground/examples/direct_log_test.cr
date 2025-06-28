require "../../src/azu"

# Direct test of log formatting with exceptions
class DirectLogTest
  def self.run
    puts "🔍 Direct Log Formatter Test"
    puts "=" * 50

    # Test 1: Log with exception using the configured logger
    begin
      raise "Test exception for direct logging"
    rescue ex
      Log.error(exception: ex) { "This should show the exception details" }
    end

    puts "\n" + "=" * 50

    # Test 2: Test the LogFormat directly
    begin
      raise "Direct formatter test exception"
    rescue ex
      entry = Log::Entry.new("test", Log::Severity::Error, "Direct formatter test", Log::Metadata.new, ex)
      io = IO::Memory.new
      formatter = Azu::LogFormat.new(entry, io)
      formatter.run
      puts io.to_s
    end

    puts "\n" + "=" * 50

    # Test 3: Test with custom exception that has additional fields
    begin
      context = Azu::ErrorContext.new(
        request_id: "test_req_123",
        endpoint: "/test",
        method: "GET",
        ip_address: "127.0.0.1"
      )
      raise Azu::Response::ValidationError.new({"email" => ["is required"]}, context)
    rescue ex
      Log.error(exception: ex) { "Custom exception with additional fields" }
    end

    puts "\n✅ Direct Log Test Completed"
  end
end

DirectLogTest.run
