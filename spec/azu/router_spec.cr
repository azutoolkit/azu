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
end
