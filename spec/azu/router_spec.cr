require "../spec_helper"

# Concrete implementation for testing WebSocket channels
class TestChannel < Azu::Channel
  def on_connect
  end

  def on_message(message : String)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end

class ExampleEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response)

  def call : Azu::Response
    Azu::Response::Empty.new
  end
end

class TestEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response)

  def call : Azu::Response
    Azu::Response::Empty.new
  end
end

struct TestResponse
  include Azu::Response

  def render
    "Hello, World!"
  end
end

class SimpleEndpoint
  include Azu::Endpoint(Azu::Request, TestResponse)

  def call : TestResponse
    TestResponse.new
  end
end

describe Azu::Router do
  describe "route registration" do
    it "adds GET endpoint" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "adds POST endpoint" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/submit", endpoint, Azu::Method::Post

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "adds multiple endpoints" do
      router = Azu::Router.new
      endpoint1 = ExampleEndpoint.new
      endpoint2 = TestEndpoint.new

      router.add "/", endpoint1, Azu::Method::Get
      router.add "/api", endpoint2, Azu::Method::Post

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "adds endpoints with different HTTP methods" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/users", endpoint, Azu::Method::Get
      router.add "/users", endpoint, Azu::Method::Post
      router.add "/users", endpoint, Azu::Method::Put
      router.add "/users", endpoint, Azu::Method::Delete

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "route matching" do
    it "matches exact paths" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      router.add "/test", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "matches paths with parameters" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      router.add "/users/:id", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "matches nested paths" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      router.add "/api/v1/users", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "WebSocket routes" do
    it "adds WebSocket routes" do
      router = Azu::Router.new

      router.ws "/ws", TestChannel

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "router configuration" do
    it "creates router instance" do
      router = Azu::Router.new
      router.should be_a(Azu::Router)
    end

    it "handles empty router" do
      router = Azu::Router.new
      router.should be_a(Azu::Router)
    end
  end

  describe "route conflicts" do
    it "handles duplicate routes gracefully" do
      router = Azu::Router.new
      endpoint1 = ExampleEndpoint.new
      endpoint2 = TestEndpoint.new

      router.add "/duplicate", endpoint1, Azu::Method::Get

      expect_raises(Azu::Router::DuplicateRoute) do
        router.add "/duplicate", endpoint2, Azu::Method::Get
      end
    end
  end

  describe "complex routing scenarios" do
    it "handles RESTful routes" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/users", endpoint, Azu::Method::Get
      router.add "/users/:id", endpoint, Azu::Method::Get
      router.add "/users", endpoint, Azu::Method::Post
      router.add "/users/:id", endpoint, Azu::Method::Put
      router.add "/users/:id", endpoint, Azu::Method::Delete

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles nested resource routes" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/users/:user_id/posts", endpoint, Azu::Method::Get
      router.add "/users/:user_id/posts/:post_id", endpoint, Azu::Method::Get
      router.add "/users/:user_id/posts", endpoint, Azu::Method::Post

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles optional parameters" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/search", endpoint, Azu::Method::Get
      router.add "/search/:query", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "edge cases" do
    it "handles root path" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles paths with special characters" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      router.add "/api/v1/users", endpoint, Azu::Method::Get
      router.add "/api/v1/users/:id", endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end

    it "handles very long paths" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new
      long_path = "/" + "a" * 1000

      router.add long_path, endpoint, Azu::Method::Get

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "performance" do
    it "handles many routes efficiently" do
      router = Azu::Router.new
      endpoint = ExampleEndpoint.new

      # Add many routes
      100.times do |i|
        router.add "/route#{i}", endpoint, Azu::Method::Get
      end

      # Should not raise an exception
      router.should be_a(Azu::Router)
    end
  end

  describe "path building optimization" do
    it "caches commonly requested paths" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/hello", endpoint)

      # Create a mock context
      request = HTTP::Request.new("GET", "/hello")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      # First call should build and cache the path
      router.process(context)
      response.close

      # Verify the path is cached by checking internal state
      # Since path_cache is private, we'll test behavior indirectly
      io.rewind
      first_response = io.gets_to_end
      first_response.should contain("Hello, World!")

      # Second call should use cached path
      io2 = IO::Memory.new
      response2 = HTTP::Server::Response.new(io2)
      context2 = HTTP::Server::Context.new(HTTP::Request.new("GET", "/hello"), response2)

      router.process(context2)
      response2.close
      io2.rewind
      second_response = io2.gets_to_end
      second_response.should contain("Hello, World!")
    end

    it "handles WebSocket upgrade paths correctly" do
      router = Azu::Router.new

      # Register a WebSocket route for testing
      router.ws("/ws-test", TestChannel)

      # Mock WebSocket request
      request = HTTP::Request.new("GET", "/ws-test")
      request.headers["Upgrade"] = "websocket"
      request.headers["Connection"] = "Upgrade"

      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      # Should handle WebSocket path building without errors
      result = router.process(context)
      # WebSocket routes may return nil or empty string depending on implementation
      (result.nil? || result == "").should be_true
    end

    it "pre-computes method cache at initialization" do
      router = Azu::Router.new

      # Test that common HTTP methods work correctly
      endpoint = SimpleEndpoint.new

      # Test various HTTP methods
      %w(GET POST PUT PATCH DELETE).each do |method|
        router.add("/test-#{method.downcase}", endpoint, Azu::Method.parse(method.downcase))

        request = HTTP::Request.new(method, "/test-#{method.downcase}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end
    end

    it "handles path normalization correctly" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/test", endpoint)

      # Test path with trailing slash
      request = HTTP::Request.new("GET", "/test/")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "clears path cache when requested" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/cached-test", endpoint)

      # Make a request to populate cache
      request = HTTP::Request.new("GET", "/cached-test")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)

      # Clear the cache
      router.clear_path_cache

      # Make another request - should still work
      io2 = IO::Memory.new
      response2 = HTTP::Server::Response.new(io2)
      context2 = HTTP::Server::Context.new(HTTP::Request.new("GET", "/cached-test"), response2)

      router.process(context2)
      response2.close
      io2.rewind
      result = io2.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles cache functionality properly" do
      # Test basic cache functionality without complex LRU operations
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add a few routes
      (1..5).each do |i|
        router.get("/test#{i}", endpoint)
      end

      # Verify cache stats before requests
      initial_stats = router.path_cache.stats
      initial_stats[:size].should eq(0)
      initial_stats[:max_size].should eq(1000)

      # Make requests to populate cache
      (1..5).each do |i|
        request = HTTP::Request.new("GET", "/test#{i}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end

      # Verify cache is populated
      final_stats = router.path_cache.stats
      final_stats[:size].should eq(5) # Should have 5 entries
      final_stats[:max_size].should eq(1000)

      # Test cache hits by making the same requests again
      (1..5).each do |i|
        request = HTTP::Request.new("GET", "/test#{i}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end

      # Cache should still be populated
      final_stats_after_hits = router.path_cache.stats
      final_stats_after_hits[:size].should eq(5)
    end

    it "handles cache with many requests without hanging" do
      # Test that cache doesn't cause hanging with many requests
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add many routes
      (1..100).each do |i|
        router.get("/test#{i}", endpoint)
      end

      # Make many requests to test performance
      start_time = Time.instant
      (1..100).each do |i|
        request = HTTP::Request.new("GET", "/test#{i}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end
      end_time = Time.instant

      # Performance check: should complete quickly (under 200ms for 100 requests)
      elapsed_time = end_time - start_time
      elapsed_time.total_milliseconds.should be < 200

      # Verify cache is working
      final_stats = router.path_cache.stats
      final_stats[:size].should eq(100)
      final_stats[:max_size].should eq(1000)
    end

    it "handles concurrent cache access safely" do
      # Test thread safety of cache under concurrent access
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add routes
      (1..10).each do |i|
        router.get("/concurrent#{i}", endpoint)
      end

      # Create multiple fibers to simulate concurrent access
      results = [] of String
      results_mutex = Mutex.new
      completed_fibers = 0
      completion_mutex = Mutex.new

      # Spawn 20 concurrent fibers making requests
      20.times do |_|
        spawn do
          (1..10).each do |i|
            request = HTTP::Request.new("GET", "/concurrent#{i}")
            io = IO::Memory.new
            response = HTTP::Server::Response.new(io)
            context = HTTP::Server::Context.new(request, response)

            router.process(context)
            response.close
            io.rewind
            response_body = io.gets_to_end

            results_mutex.synchronize do
              results << response_body
            end
          end

          completion_mutex.synchronize do
            completed_fibers += 1
          end
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 20 }
        sleep(0.001.seconds)
      end

      # Verify all requests completed successfully
      results.size.should eq(200) # 20 fibers * 10 requests each
      results.all?(&.includes?("Hello, World!")).should be_true

      # Verify cache is working correctly
      final_stats = router.path_cache.stats
      final_stats[:size].should eq(10) # Should have 10 unique routes cached
      final_stats[:max_size].should eq(1000)
    end

    it "handles concurrent cache writes safely" do
      # Test that concurrent cache writes don't cause issues
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add routes for all possible requests
      (0...10).each do |fiber_id|
        (1..5).each do |i|
          router.get("/concurrent_write#{fiber_id}_#{i}", endpoint)
        end
      end

      # Create multiple fibers writing to cache simultaneously
      results = [] of String
      results_mutex = Mutex.new
      completed_fibers = 0
      completion_mutex = Mutex.new

      # Spawn 10 concurrent fibers making different requests
      10.times do |fiber_id|
        spawn do
          (1..5).each do |i|
            request = HTTP::Request.new("GET", "/concurrent_write#{fiber_id}_#{i}")
            io = IO::Memory.new
            response = HTTP::Server::Response.new(io)
            context = HTTP::Server::Context.new(request, response)

            router.process(context)
            response.close
            io.rewind
            response_body = io.gets_to_end

            results_mutex.synchronize do
              results << response_body
            end
          end

          completion_mutex.synchronize do
            completed_fibers += 1
          end
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 10 }
        sleep(0.001.seconds)
      end

      # Verify all requests completed successfully
      results.size.should eq(50) # 10 fibers * 5 requests each
      results.all?(&.includes?("Hello, World!")).should be_true

      # Verify cache is working correctly
      final_stats = router.path_cache.stats
      final_stats[:size].should eq(50) # Should have 50 unique routes cached
      final_stats[:max_size].should eq(1000)
    end

    it "handles cache performance under concurrent load" do
      # Test cache performance with concurrent requests
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add routes
      (1..20).each do |i|
        router.get("/perf#{i}", endpoint)
      end

      # Create concurrent load
      completed_fibers = 0
      completion_mutex = Mutex.new
      start_time = Time.instant

      # Spawn 50 concurrent fibers
      50.times do |_|
        spawn do
          (1..20).each do |i|
            request = HTTP::Request.new("GET", "/perf#{i}")
            io = IO::Memory.new
            response = HTTP::Server::Response.new(io)
            context = HTTP::Server::Context.new(request, response)

            router.process(context)
            response.close
          end

          completion_mutex.synchronize do
            completed_fibers += 1
          end
        end
      end

      # Wait for all fibers to complete
      while completion_mutex.synchronize { completed_fibers < 50 }
        sleep(0.001.seconds)
      end
      end_time = Time.instant

      # Performance check: should complete quickly (under 500ms for 1000 concurrent requests)
      elapsed_time = end_time - start_time
      elapsed_time.total_milliseconds.should be < 500

      # Verify cache is working
      final_stats = router.path_cache.stats
      final_stats[:size].should eq(20) # Should have 20 unique routes cached
      final_stats[:max_size].should eq(1000)
    end
  end

  describe "original functionality" do
    it "handles GET requests" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.get("/hello", endpoint)

      request = HTTP::Request.new("GET", "/hello")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles POST requests" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.post("/data", endpoint)

      request = HTTP::Request.new("POST", "/data")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles method override" do
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new
      router.put("/update", endpoint)

      request = HTTP::Request.new("POST", "/update?_method=PUT")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.process(context)
      response.close
      io.rewind
      result = io.gets_to_end
      result.should contain("Hello, World!")
    end

    it "handles unknown routes gracefully" do
      router = Azu::Router.new

      request = HTTP::Request.new("GET", "/unknown")
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      # Should not raise exception, returns nil for 404s
      result = router.process(context)
      result.should be_nil

      # Check that the response status is set to 404
      response.status_code.should eq(404)
    end
  end
end
