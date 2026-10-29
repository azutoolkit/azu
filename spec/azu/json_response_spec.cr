require "../spec_helper"

private struct JsonResponseRequest
  include Azu::Request
end

private struct JsonResponseEndpoint
  include Azu::Endpoint(JsonResponseRequest, Azu::Response::Json(NamedTuple(message: String)))

  def call : Azu::Response::Json(NamedTuple(message: String))
    status 201
    Azu::Response::Json.new({message: "quote: \" / unicode: ☃\n" * 1024})
  end
end

describe Azu::Response::Json do
  it "serializes typed values, escaping strings without an intermediate generic hash" do
    value = {id: 7, active: true, missing: nil, items: ["☃", "\n\""]}
    response = Azu::Response::Json.new(value)
    response.render.should eq value.to_json
    output = IO::Memory.new
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(output))
    response.write_to(context)
    # JSON::Builder normally flushes at end_document. Doing that on the response
    # prematurely commits headers and forces tiny JSON documents to be chunked.
    output.size.should eq 0
    context.response.close
    parsed = HTTP::Client::Response.from_io(IO::Memory.new(output.to_s))
    parsed.headers["Content-Type"].should eq "application/json"
    parsed.headers["Content-Length"].should eq value.to_json.bytesize.to_s
    parsed.headers.has_key?("Transfer-Encoding").should be_false
    parsed.body.should eq value.to_json
  end

  it "frames large responses and suppresses HEAD bodies on a reused connection" do
    router = Azu::Router.new
    router.get "/json", JsonResponseEndpoint.new
    input = IO::Memory.new("HEAD /json HTTP/1.1\r\nHost: local\r\n\r\nGET /json HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")
    output = IO::Memory.new
    handler = ->(context : HTTP::Server::Context) { router.process(context); nil }
    HTTP::Server::RequestProcessor.new(handler).process(input, output)
    wire = IO::Memory.new(output.to_s)
    head = HTTP::Client::Response.from_io(wire, ignore_body: true)
    head.status_code.should eq 201
    head.headers["Content-Type"].should eq "application/json"
    get = HTTP::Client::Response.from_io(wire)
    get.status_code.should eq 201
    JSON.parse(get.body)["message"].as_s.should eq "quote: \" / unicode: ☃\n" * 1024
  end
end
