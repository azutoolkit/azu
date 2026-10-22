require "../spec_helper"
require "http/client"

private struct WhoAmI
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "#{Azu.current_config.env}:#{Azu.current_config.upload.max_file_size}"
    context
  end
end

private class SeenConfigChannel < Azu::Channel
  SEEN = ::Channel(String).new(4)

  def on_connect
  end

  def on_message(message : String)
    spawned = ::Channel(String).new
    Azu.spawn_scoped { spawned.send(Azu.current_config.env.to_s) }
    SEEN.send("#{Azu.current_config.env}/#{spawned.receive}")
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

private def build_app(env : Azu::Environment, limit : UInt64, path : String) : Azu::App
  app = Azu::App.new
  app.config.env = env
  app.config.upload.max_file_size = limit
  app.router.get path, WhoAmI.new
  app
end

private def serve(app : Azu::App, &)
  server = app.server([Azu::Handler::RequestId.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

describe Azu::App do
  it "serves two apps in one process, each with its own routes and configuration" do
    first = build_app(Azu::Environment::Production, 111_u64, "/first")
    second = build_app(Azu::Environment::Test, 222_u64, "/second")

    serve(first) do |one|
      serve(second) do |two|
        one.get("/first").body.should eq "Production:111"
        two.get("/second").body.should eq "Test:222"
        one.get("/second").status_code.should eq 404
        two.get("/first").status_code.should eq 404
      end
    end
  end

  it "leaves the global configuration alone" do
    before = Azu::CONFIG.env

    serve(build_app(Azu::Environment::Production, 1_u64, "/x")) { |client| client.get("/x") }

    Azu::CONFIG.env.should eq before
  end

  it "wraps the global configuration for the default app" do
    Azu::App.default.config.should be Azu::CONFIG
    Azu::App.default.router.should be Azu::CONFIG.router
  end

  it "gives WebSocket callbacks and scoped fibers the configuration of the app that accepted them" do
    app = build_app(Azu::Environment::Production, 1_u64, "/x")
    app.router.ws "/chan", SeenConfigChannel

    serve(app) do |_|
      server = app.server([] of HTTP::Handler)
      address = server.bind_unused_port("127.0.0.1")
      spawn { server.listen }
      Fiber.yield
      begin
        socket = HTTP::WebSocket.new("127.0.0.1", "/chan", address.port)
        socket.send "hi"
        spawn { socket.run }
        select
        when seen = SeenConfigChannel::SEEN.receive
          seen.should eq "Production/Production"
        when timeout(5.seconds)
          fail "no message reached the channel"
        end
        socket.close
      ensure
        server.close
      end
    end
  end

  it "keeps the outer configuration when scopes are nested" do
    outer = Azu::Configuration.new
    inner = Azu::Configuration.new

    Azu.with_config(outer) do
      Azu.with_config(inner) { Azu.current_config.should be inner }
      Azu.current_config.should be outer
    end
    Azu.current_config.should be Azu::CONFIG
  end

  it "refuses to serve two apps with the same handler instances" do
    handlers = [Azu::Handler::RequestId.new] of HTTP::Handler
    Azu::App.new.server(handlers)

    expect_raises(ArgumentError, /already part of a chain/) { Azu::App.new.server(handlers) }
  end
end
