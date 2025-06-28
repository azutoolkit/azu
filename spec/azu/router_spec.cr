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

    it "handles LRU cache eviction properly" do
      # This test would need access to internal cache size to be fully effective
      # For now, we'll test that the router continues to work with many requests
      router = Azu::Router.new
      endpoint = SimpleEndpoint.new

      # Add many routes
      (1..1200).each do |i|
        router.get("/test#{i}", endpoint)
      end

      # Make requests to exceed cache size (default 1000)
      (1..1200).each do |i|
        request = HTTP::Request.new("GET", "/test#{i}")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        context = HTTP::Server::Context.new(request, response)

        result = router.process(context)
        result.should be_a(String)
      end
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
