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
    explicit = Log.for("handler-log-explicit")
    Azu::Handler::Logger.new(explicit).log.should eq explicit
  end

  it "uses the app's log in default_handlers" do
    app = Azu::App.new
    app.config.log = Log.for("handler-log-defaults")
    logger = app.default_handlers.find(&.is_a?(Azu::Handler::Logger)).as(Azu::Handler::Logger)
    logger.log.should eq app.config.log
  end
end
