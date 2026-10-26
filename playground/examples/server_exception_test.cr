require "../../src/azu"

# Opt in to Azu's log format; requiring azu no longer configures Log
Azu.setup_logging
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

  # PORT when it is set, otherwise a port the system chooses
  configure do |config|
    config.port = ENV["PORT"]?.try(&.to_i?) || 0
  end

  def self.start_test
    puts "🧪 Starting Server Exception Test"
    puts "=" * 50

    app = Azu::App.default
    stopped = ::Channel(Nil).new

    # Start the server in the background; `stop` below ends it
    spawn do
      app.start([
        Azu::Handler::Rescuer.new,
        Azu::Handler::SimpleLogger.new,
      ] of HTTP::Handler, signals: false)
      stopped.close
    end

    # Wait until the server is bound
    address = nil
    50.times do
      break if address = app.address
      sleep 100.milliseconds
    end
    abort "The server did not start" unless address

    # Make request that will trigger exception
    begin
      response = HTTP::Client.get("http://#{address}/test-exception")
      puts "Response status: #{response.status_code}"
    rescue ex
      puts "Request failed: #{ex.message}"
    end

    # Stopping the app writes the log entries still queued
    app.stop
    stopped.receive?

    puts "\n✅ Server Exception Test Completed"
    puts "Check the logs above for exception details!"
  end
end

TestApp.start_test
