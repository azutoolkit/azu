require "../../src/azu"

# Test exception handling in logs
class ExceptionTest
  def self.run
    puts "🧪 Testing Exception Display in Logs"
    puts "=" * 50

    # Test standard exception logging
    begin
      raise "This is a test exception with a message"
    rescue ex
      Log.error(exception: ex) { "Standard exception test" }
    end

    # Test exception with no message
    begin
      raise Exception.new
    rescue ex
      Log.error(exception: ex) { "Exception with no message test" }
    end

    # Test nested exception
    begin
      begin
        raise "Inner exception"
      rescue ex
        raise "Outer exception caused by inner"
      end
    rescue ex
      Log.warn(exception: ex) { "Nested exception test" }
    end

    # Test async logging with exception
    async_logger = Azu::AsyncLogging::AsyncLogger.new("exception_test")

    begin
      raise "Async logging exception test"
    rescue ex
      async_logger.error("Async exception occurred", {
        "test_type" => "async_exception",
        "severity"  => "high",
      }, ex)
    end

    # Give async logger time to process
    sleep(1.second)

    puts "\n✅ Exception Test Completed"
    puts "Check the logs above to see exception formatting!"
  end
end

ExceptionTest.run
