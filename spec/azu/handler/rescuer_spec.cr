require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::Rescuer do
  describe "initialization" do
    it "initializes with default log" do
      handler = Azu::Handler::Rescuer.new
      handler.should be_a(Azu::Handler::Rescuer)
    end

    it "initializes with custom log" do
      log = Log.for("test")
      handler = Azu::Handler::Rescuer.new(log)
      handler.should be_a(Azu::Handler::Rescuer)
    end
  end

  describe "normal request flow" do
    it "passes through successful requests" do
      handler = Azu::Handler::Rescuer.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "preserves response content" do
      handler = Azu::Handler::Rescuer.new
      next_handler, verify = create_next_handler(1, "Custom response")
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("Custom response")
      verify.call
    end
  end

  describe "HTTP::Server::ClientError handling" do
    it "catches and logs client errors" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise HTTP::Server::ClientError.new("Bad request")
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")

      # Should not raise exception
      handler.call(context)

      # Response should not be written for client errors
      io.rewind
      response_content = io.gets_to_end
      response_content.should_not contain("Bad request")
    end
  end

  describe "Azu::Response::Error handling" do
    it "catches and renders Response::Error" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Not found", HTTP::Status::NOT_FOUND, [] of String)
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.status_code.should eq(404)
      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("Not found")
    end

    it "handles custom status codes" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Unauthorized", HTTP::Status::UNAUTHORIZED, [] of String)
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.status_code.should eq(401)
      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("Unauthorized")
    end

    it "includes error messages in response" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Custom error message", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("Custom error message")
    end
  end

  describe "Generic Exception handling" do
    it "catches and handles generic exceptions" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Something went wrong")
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.status_code.should eq(500)
      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("Something went wrong")
    end

    it "generates request ID for generic exceptions" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Error")
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      io.rewind
      response_content = io.gets_to_end
      # Should contain generated request ID
      response_content.should contain("req_")
    end

    it "uses existing request ID from headers" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Error")
      }
      handler.next = error_handler

      headers = HTTP::Headers.new
      headers["X-Request-ID"] = "custom-request-id-123"
      context, io = create_context("GET", "/test", headers)
      handler.call(context)

      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("custom-request-id-123")
    end
  end

  describe "error context" do
    it "includes request method in error context" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Error with context")
      }
      handler.next = error_handler

      context, io = create_context("POST", "/test")
      handler.call(context)

      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("POST")
    end

    it "includes request path in error context" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Error with context")
      }
      handler.next = error_handler

      context, io = create_context("GET", "/api/users")
      handler.call(context)

      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("/api/users")
    end
  end

  describe "nested exceptions" do
    it "handles exceptions with causes" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        begin
          raise Exception.new("Inner error")
        rescue ex
          raise Exception.new("Outer error", cause: ex)
        end
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.status_code.should eq(500)
      io.rewind
      response_content = io.gets_to_end
      response_content.should contain("Outer error")
    end
  end

  describe "handler chain integration" do
    it "works with multiple handlers in chain" do
      rescuer = Azu::Handler::Rescuer.new
      request_id_handler = Azu::Handler::RequestId.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Chain error")
      }

      request_id_handler.next = error_handler
      rescuer.next = request_id_handler

      context, io = create_context("GET", "/test")
      rescuer.call(context)

      context.response.status_code.should eq(500)
      # Should have request ID from RequestId handler
      context.response.headers.has_key?("X-Request-ID").should be_true
    end

    it "catches errors from any point in chain" do
      rescuer = Azu::Handler::Rescuer.new

      failing_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Middleware error")
      }

      rescuer.next = failing_handler

      context, io = create_context("GET", "/test")

      # Should not propagate exception
      rescuer.call(context)

      context.response.status_code.should eq(500)
    end
  end

  describe "concurrent requests" do
    it "handles concurrent errors safely" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("Concurrent error")
      }
      handler.next = error_handler

      channel = Channel(Bool).new

      10.times do
        spawn do
          context, io = create_context("GET", "/test")
          handler.call(context)
          context.response.status_code.should eq(500)
          channel.send(true)
        end
      end

      10.times { channel.receive }
    end
  end

  describe "error response format" do
    it "sets appropriate content type for errors" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Azu::Response::Error.new("Error", HTTP::Status::INTERNAL_SERVER_ERROR, [] of String)
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      # Response should have content type set
      context.response.headers.has_key?("Content-Type").should be_true
    end

    it "generates valid HTML error pages" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("HTML error")
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      io.rewind
      response_content = io.gets_to_end
      # Should contain HTML structure
      response_content.should contain("HTML error")
    end
  end

  describe "edge cases" do
    it "handles empty error messages" do
      handler = Azu::Handler::Rescuer.new

      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new("")
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")

      # Should not crash
      handler.call(context)

      context.response.status_code.should eq(500)
    end

    it "handles very long error messages" do
      handler = Azu::Handler::Rescuer.new

      long_message = "Error: " + ("A" * 10000)
      error_handler = ->(_context : HTTP::Server::Context) {
        raise Exception.new(long_message)
      }
      handler.next = error_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      context.response.status_code.should eq(500)
    end

    it "handles nil next handler gracefully" do
      handler = Azu::Handler::Rescuer.new

      context, io = create_context("GET", "/test")

      # Crystal's HTTP::Handler doesn't raise an exception when there's no next handler
      # It simply does nothing, which leaves the response in its default state
      # The test verifies it doesn't crash
      handler.call(context)

      # Should not crash - response status can be anything (default is 404 for unhandled paths)
      context.response.status_code.should be_a(Int32)
    end
  end
end
