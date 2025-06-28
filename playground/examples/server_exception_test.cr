require "../../src/azu"
require "http/client"

# Test exception logging in server context
struct TestEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response)

  get "/test-exception"

  def call : Azu::Response
    # This will trigger an exception that should be logged
    raise "Test exception from endpoint"
  end
end

# Test app with exception endpoint
class TestApp
  include Azu

  def self.start_test
    puts "🧪 Starting Server Exception Test"
    puts "=" * 50

    # Register test endpoint
    TestEndpoint.get "/test-exception"

    # Start server in background
    spawn do
      TestApp.start([
        Azu::Handler::Rescuer.new,
        Azu::Handler::SimpleLogger.new,
      ])
    end

    # Give server time to start
    sleep(1)

    # Make request that will trigger exception
    begin
      response = HTTP::Client.get("http://localhost:4000/test-exception")
      puts "Response status: #{response.status_code}"
    rescue ex
      puts "Request failed: #{ex.message}"
    end

    # Give time for async logging to process
    sleep(2)

    puts "\n✅ Server Exception Test Completed"
    puts "Check the logs above for exception details!"
  end
end

TestApp.start_test
