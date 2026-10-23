require "../spec_helper"
require "http/client"

private GATE = ::Channel(Nil).new

private struct Slow
  include Azu::Routable

  def call(context : HTTP::Server::Context)
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
      wait_until { !app.drain(1.millisecond) }

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
      wait_until { !app.drain(1.millisecond) }

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

  it "has nothing in flight when idle" do
    Azu::App.new.drain(1.second).should be_true
  end
end
