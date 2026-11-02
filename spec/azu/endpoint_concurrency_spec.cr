require "../spec_helper"
require "../../src/azu/testing/testing"

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

  # A struct built with its dependencies and registered as an instance: the router keeps that one value for every request.
  struct SlowStructEndpoint
    include Azu::Endpoint(EchoRequest, EchoResponse)

    def initialize(@delay : Time::Span)
    end

    def call : EchoResponse
      sleep @delay
      status 202
      EchoResponse.new echo_request.name
    end
  end
end

describe "struct endpoints registered as instances under concurrent requests" do
  it "answers each request with its own parameters and its own status" do
    app = Azu::App.new
    app.router.post("/echo", EndpointConcurrencySpec::SlowStructEndpoint.new(30.milliseconds))
    names = %w(alpha bravo charlie delta echo foxtrot)
    results = Channel({String, String, Int32}).new
    names.each do |name|
      spawn do
        client = Azu::Testing::Client.new(app, [Azu::Handler::Rescuer.new] of HTTP::Handler)
        response = client.post("/echo", json: {name: name})
        results.send({name, response.body, response.status_code})
      end
    end

    names.size.times do
      sent, received, code = results.receive
      received.should eq sent
      code.should eq 202
    end
  end
end

describe "class endpoints under concurrent requests" do
  it "answers each request with its own parameters" do
    app = Azu::App.new
    app.routes { post "/echo", EndpointConcurrencySpec::SlowEchoEndpoint }
    names = %w(alpha bravo charlie)
    results = Channel({String, String}).new
    names.each do |name|
      spawn do
        client = Azu::Testing::Client.new(app, [Azu::Handler::Rescuer.new] of HTTP::Handler)
        response = client.post("/echo", json: {name: name})
        results.send({name, response.body})
      end
    end

    names.size.times do
      sent, received = results.receive
      received.should eq sent
    end
  end
end
