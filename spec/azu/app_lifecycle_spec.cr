require "../spec_helper"
require "http/client"

private GATE    = ::Channel(Nil).new
private ENTERED = ::Channel(Nil).new(8)

private struct Slow
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    ENTERED.send(nil)
    GATE.receive
    context.response << "finished"
    context
  end
end

private def start(app : Azu::App) : HTTP::Client
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  HTTP::Client.new(address.address, address.port)
end

private def slow_app : Azu::App
  app = Azu::App.new
  app.routes { get "/slow", Slow }
  app
end

describe Azu::App do
  describe "#stop" do
    it "lets a request in flight finish and reports that nothing was dropped" do
      app = slow_app
      client = start(app)
      body = ::Channel(String).new
      spawn { body.send client.get("/slow").body }
      ENTERED.receive

      stopped = ::Channel(Bool).new
      spawn { stopped.send app.stop(5.seconds) }
      Fiber.yield
      GATE.send(nil)

      stopped.receive.should be_true
      body.receive.should eq "finished"
    end

    it "gives up on a request that outlasts the timeout" do
      app = slow_app
      client = start(app)
      spawn { client.get("/slow") rescue nil }
      ENTERED.receive

      app.stop(50.milliseconds).should be_false
      GATE.send(nil)
    end

    it "stops accepting connections" do
      app = slow_app
      client = start(app)
      app.stop(1.second).should be_true

      expect_raises(IO::Error) { HTTP::Client.new(client.host, client.port).get("/slow") }
    end
  end

  describe "#begin_shutdown" do
    it "answers 503 on a connection that stays open after the listener closed" do
      app = slow_app
      client = start(app)
      spawn { client.get("/slow") }
      ENTERED.receive

      app.begin_shutdown
      other = HTTP::Client.new(client.host, client.port)
      response = other.get("/slow")
      response.status_code.should eq 503
      response.headers["Connection"].should eq "close"
      GATE.send(nil)
    end
  end

  describe "#track" do
    it "releases the request when the block raises" do
      app = Azu::App.new
      expect_raises(Exception, "boom") { app.track { raise "boom" } }
      app.drain(0.seconds).should be_true
    end
  end

  it "has nothing in flight when idle, whatever the timeout" do
    Azu::App.new.drain(1.second).should be_true
    Azu::App.new.drain(0.seconds).should be_true
  end

  it "reads the shutdown timeout from SHUTDOWN_TIMEOUT, ignoring what is not a number" do
    {"5" => 5, "0" => 0, "-3" => 0, "30s" => 30, "" => 30}.each do |value, seconds|
      ENV["SHUTDOWN_TIMEOUT"] = value
      Azu::Configuration.new.shutdown_timeout.should eq seconds.seconds
    end
  ensure
    ENV.delete("SHUTDOWN_TIMEOUT")
  end
end
