require "../spec_helper"
require "log/spec"
require "http/client"

private struct Ping
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << "pong"
    context
  end
end

describe "handler log defaults" do
  it "logs a handler built without log: to the log of the app that serves the request" do
    app = Azu::App.new
    app.config.log = Log.for("handler-log-app")
    app.routes { get "/ping", Ping }
    server = app.server([Azu::Handler::Logger.new] of HTTP::Handler)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    Log.capture("handler-log-app") do |logs|
      HTTP::Client.new(address.address, address.port).get("/ping").body.should eq "pong"
      logs.check(:info, /\/ping/)
    end
  ensure
    server.try(&.close)
  end

  it "keeps an explicit log: over the app's" do
    app_config = Azu::Configuration.new
    app_config.log = Log.for("handler-log-app-config")
    explicit = Log.for("handler-log-explicit")
    Azu.with_config(app_config) do
      Azu::Handler::Logger.new(explicit).log.should eq explicit
      Azu::Handler::SimpleLogger.new(explicit).log.should eq explicit
    end
  end

  it "resolves SimpleLogger's and Logger's default log from the current config, not at construction" do
    app_config = Azu::Configuration.new
    app_config.log = Log.for("handler-log-simple")
    logger = Azu::Handler::Logger.new
    simple = Azu::Handler::SimpleLogger.new
    Azu.with_config(app_config) do
      logger.log.should eq app_config.log
      simple.log.should eq app_config.log
    end
  end

  it "logs a Throttle block to the log of the current config" do
    app_config = Azu::Configuration.new
    app_config.log = Log.for("handler-log-throttle")
    throttle = Azu::Handler::Throttle.new(60, 60, 1, [] of String, [] of String)
    throttle.next = ->(context : HTTP::Server::Context) { }
    Log.capture("handler-log-throttle") do |logs|
      Azu.with_config(app_config) do
        3.times do
          io = IO::Memory.new
          request = HTTP::Request.new("GET", "/", HTTP::Headers.new)
          request.remote_address = Socket::IPAddress.new("10.1.1.1", 4000)
          throttle.call(HTTP::Server::Context.new(request, HTTP::Server::Response.new(io)))
        end
      end
      logs.check(:warn, /blocked/)
    end
  end
end
