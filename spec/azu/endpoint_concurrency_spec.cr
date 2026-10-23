require "../spec_helper"
require "http/client"

module EndpointConcurrencySpec
  struct EchoRequest
    include Azu::Request

    getter name : String

    def initialize(@name = "")
    end
  end

  struct EchoResponse
    include Azu::Response

    def initialize(@name : String)
    end

    def render
      @name
    end
  end

  # Yields between the start of the request and reading its parameters, as any endpoint that waits
  # for a database or a service does.
  class SlowEchoEndpoint
    include Azu::Endpoint(EchoRequest, EchoResponse)

    def call : EchoResponse
      sleep 30.milliseconds
      EchoResponse.new echo_request.name
    end
  end
end

describe "class endpoints under concurrent requests" do
  it "answers each request with its own parameters" do
    app = Azu::App.new
    app.routes { post "/echo", EndpointConcurrencySpec::SlowEchoEndpoint }
    server = app.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    names = %w(alpha bravo charlie)
    results = Channel({String, String}).new
    names.each do |name|
      spawn do
        response = HTTP::Client.new(address.address, address.port).post("/echo", HTTP::Headers{"Content-Type" => "application/json"}, %({"name": "#{name}"}))
        results.send({name, response.body})
      end
    end

    begin
      names.size.times do
        sent, received = results.receive
        received.should eq sent
      end
    ensure
      server.close
    end
  end
end
