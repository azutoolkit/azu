require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

# Test channel implementation
class IntegrationTestChannel < Azu::Channel
  property connect_called = false
  property message_received : String? = nil

  def on_connect
    @connect_called = true
  end

  def on_message(message : String)
    @message_received = message
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

describe "WebSocket Integration" do
  describe "channel lifecycle" do
    it "creates and initializes channel" do
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)
      channel = IntegrationTestChannel.new(socket)

      channel.should be_a(Azu::Channel)
      channel.socket.should eq(socket)
    end

    it "calls on_connect during initialization" do
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)
      channel = IntegrationTestChannel.new(socket)

      context = HTTP::Server::Context.new(
        HTTP::Request.new("GET", "/"),
        HTTP::Server::Response.new(IO::Memory.new)
      )

      channel.call(context)
      channel.connect_called.should be_true
    end
  end

  describe "WebSocket with RequestID" do
    it "tracks WebSocket connections with request IDs" do
      request_id = Azu::Handler::RequestId.new

      ws_handler = ->(ctx : HTTP::Server::Context) {
        # Simulate WebSocket handling
        ctx.response.print "WebSocket"
      }
      request_id.next = ws_handler

      headers = HTTP::Headers.new
      headers["Upgrade"] = "websocket"
      headers["Connection"] = "Upgrade"
      context, _ = create_context("GET", "/ws", headers)

      request_id.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      context.response.headers.has_key?("X-Request-ID").should be_true
    end
  end

  describe "WebSocket with CORS" do
    it "validates origin for WebSocket upgrade" do
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])

      ws_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.print "WebSocket OK"
      }
      cors.next = ws_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Upgrade"] = "websocket"
      headers["Connection"] = "Upgrade"
      context, io = create_context("GET", "/ws", headers)

      cors.call(context)

      get_response_body(context, io).should eq("WebSocket OK")
      context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
    end

    it "blocks WebSocket from invalid origin" do
      cors = Azu::Handler::CORS.new(origins: ["https://allowed.com"])

      ws_handler, verify = create_next_handler(0)
      cors.next = ws_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://evil.com"
      headers["Upgrade"] = "websocket"
      context, _ = create_context("GET", "/ws", headers)

      cors.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "WebSocket error handling" do
    it "handles errors in WebSocket setup" do
      rescuer = Azu::Handler::Rescuer.new

      error_handler = ->(_ctx : HTTP::Server::Context) {
        raise Exception.new("WebSocket error")
      }
      rescuer.next = error_handler

      headers = HTTP::Headers.new
      headers["Upgrade"] = "websocket"
      context, _ = create_context("GET", "/ws", headers)

      rescuer.call(context)

      context.response.status_code.should eq(500)
    end
  end

  describe "WebSocket with full handler chain" do
    it "processes WebSocket through complete chain" do
      request_id = Azu::Handler::RequestId.new
      rescuer = Azu::Handler::Rescuer.new
      logger = Azu::Handler::Logger.new
      cors = Azu::Handler::CORS.new(origins: ["*"])

      ws_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.print "WebSocket Connected"
      }

      cors.next = ws_handler
      logger.next = cors
      rescuer.next = logger
      request_id.next = rescuer

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Upgrade"] = "websocket"
      headers["Connection"] = "Upgrade"
      context, io = create_context("GET", "/ws", headers)

      request_id.call(context)

      context.request.headers.has_key?("X-Request-ID").should be_true
      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_true
      get_response_body(context, io).should eq("WebSocket Connected")
    end
  end

  describe "concurrent WebSocket connections" do
    it "handles multiple connections" do
      channels = [] of IntegrationTestChannel

      5.times do
        io = IO::Memory.new
        socket = HTTP::WebSocket.new(io)
        channel = IntegrationTestChannel.new(socket)
        channels << channel

        context = HTTP::Server::Context.new(
          HTTP::Request.new("GET", "/"),
          HTTP::Server::Response.new(IO::Memory.new)
        )
        channel.call(context)
      end

      channels.each do |channel|
        channel.connect_called.should be_true
      end
    end
  end

  describe "WebSocket with monitoring" do
    it "tracks WebSocket metrics" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)

      ws_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.print "WS"
      }
      performance.next = ws_handler

      headers = HTTP::Headers.new
      headers["Upgrade"] = "websocket"
      context, _ = create_context("GET", "/ws", headers)

      performance.call(context)

      stats = performance.stats
      stats.total_requests.should eq(1)
    end
  end

  describe "WebSocket security chain" do
    it "applies security handlers to WebSocket" do
      request_id = Azu::Handler::RequestId.new
      ip_spoofing = Azu::Handler::IpSpoofing.new
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])

      ws_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.print "Secure WS"
      }

      cors.next = ws_handler
      ip_spoofing.next = cors
      request_id.next = ip_spoofing

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Upgrade"] = "websocket"
      headers["X-Forwarded-For"] = "192.168.1.1"
      context, io = create_context("GET", "/ws", headers)

      request_id.call(context)

      get_response_body(context, io).should eq("Secure WS")
      context.request.headers.has_key?("X-Request-ID").should be_true
    end

    it "blocks WebSocket on security violation" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      ws_handler, verify = create_next_handler(0)
      ip_spoofing.next = ws_handler

      headers = HTTP::Headers.new
      headers["Upgrade"] = "websocket"
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1" # Spoofed
      context, _ = create_context("GET", "/ws", headers)

      ip_spoofing.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "channel route registration" do
    it "registers WebSocket routes in router" do
      router = Azu::Router.new

      # Register WebSocket route
      router.ws("/ws-test", IntegrationTestChannel)

      router.should be_a(Azu::Router)
    end
  end

  describe "WebSocket upgrade handling" do
    it "detects WebSocket upgrade requests" do
      headers = HTTP::Headers.new
      headers["Upgrade"] = "websocket"
      headers["Connection"] = "Upgrade"

      context, _ = create_context("GET", "/ws", headers)

      context.request.headers["Upgrade"]?.should eq("websocket")
      context.request.headers["Connection"]?.should eq("Upgrade")
    end
  end

  describe "channel message handling" do
    it "routes messages to channel handlers" do
      io = IO::Memory.new
      socket = HTTP::WebSocket.new(io)
      channel = IntegrationTestChannel.new(socket)

      context = HTTP::Server::Context.new(
        HTTP::Request.new("GET", "/"),
        HTTP::Server::Response.new(IO::Memory.new)
      )

      channel.call(context)
      channel.connect_called.should be_true
    end
  end

  describe "WebSocket performance" do
    it "handles WebSocket connections efficiently" do
      metrics = Azu::PerformanceMetrics.new
      performance = Azu::Handler::PerformanceMonitor.new(metrics)

      ws_handler = ->(ctx : HTTP::Server::Context) {
        ctx.response.print "Fast WS"
      }
      performance.next = ws_handler

      10.times do
        headers = HTTP::Headers.new
        headers["Upgrade"] = "websocket"
        context, _ = create_context("GET", "/ws", headers)
        performance.call(context)
      end

      stats = performance.stats
      stats.total_requests.should eq(10)
      stats.avg_response_time.should be < 100
    end
  end
end
