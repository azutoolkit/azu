require "../spec_helper"
require "http/client"

# Requests that go through a real HTTP::Server on a real socket, with the router and the
# handler chain the way Azu.start wires them, instead of calling handlers on a hand-built context.
module WireSpec
  struct EchoRequest
    include Azu::Request

    @id : Int64?
    @users : Array(String)

    getter id, users

    def initialize(@id : Int64? = nil, @users : Array(String) = [] of String)
    end
  end

  struct EchoResponse
    include Azu::Response

    def initialize(@request : EchoRequest)
    end

    def render
      {id: @request.id, users: @request.users}.to_json
    end
  end

  # Endpoints are classes on purpose: a struct endpoint inherits `HTTP::Handler#next`, a union that
  # contains the struct itself, and a handler chain in front of it then corrupts memory.
  class EchoEndpoint
    include Azu::Endpoint(EchoRequest, EchoResponse)
    post "/wire/echo/:id"

    def call : EchoResponse
      status 200
      content_type "application/json"
      EchoResponse.new echo_request
    end
  end

  struct HelloResponse
    include Azu::Response

    def initialize(@name : String)
    end

    def render
      "Welcome, #{@name}"
    end
  end

  class HelloEndpoint
    include Azu::Endpoint(Azu::Request, HelloResponse)
    get "/wire/hello/:name"

    def call : HelloResponse
      content_type "text/plain"
      HelloResponse.new params["name"]
    end
  end

  def self.serve(&)
    handlers = [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new] of HTTP::Handler
    server = HTTP::Server.new(handlers) { |context| Azu::CONFIG.router.process(context) }
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield
    begin
      yield HTTP::Client.new(address.address, address.port)
    ensure
      server.close
    end
  end
end

describe "Azu over a real connection" do
  it "turns a JSON body into the request struct and renders the response" do
    payload = {id: 1, users: ["John", "Paul"]}
    headers = HTTP::Headers{"Accept" => "application/json", "Content-Type" => "application/json"}

    WireSpec.serve do |client|
      response = client.post "/wire/echo/1", headers: headers, body: payload.to_json

      response.status_code.should eq 200
      JSON.parse(response.body).should eq JSON.parse(payload.to_json)
    end
  end

  it "answers an unknown path with a 404 that names it" do
    WireSpec.serve do |client|
      response = client.get "/wire/invalid_path", headers: HTTP::Headers{"Accept" => "text/plain"}

      response.status_code.should eq 404
      response.body.should contain "/wire/invalid_path"
    end
  end

  it "serves a path parameter and stamps a request id" do
    WireSpec.serve do |client|
      response = client.get "/wire/hello/world", headers: HTTP::Headers{"Accept" => "text/plain"}

      response.status_code.should eq 200
      response.body.should eq "Welcome, world"
      response.headers["X-Request-ID"]?.should_not be_nil
    end
  end

  it "rejects a body that is not valid JSON with a 400, not a 500" do
    headers = HTTP::Headers{"Accept" => "application/json", "Content-Type" => "application/json"}

    WireSpec.serve do |client|
      response = client.post "/wire/echo/1", headers: headers, body: "{not json"

      response.status_code.should eq 400
    end
  end
end
