require "../spec_helper"

private struct HeadHello
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response.print "hello"
  end
end

# A `get` route answers HEAD too (RFC 9110: the same headers, no body). A body sent with it is read by a keep-alive
# client as the start of the next response.
private struct HeadLong
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response.print "hello " * 200
  end
end

private def head_and_get(handler : HTTP::Handler, path : String, headers = HTTP::Headers.new) : Tuple(HTTP::Headers, HTTP::Headers)
  {"HEAD", "GET"}.map do |method|
    io = IO::Memory.new
    context = HTTP::Server::Context.new(HTTP::Request.new(method, path, headers.dup), HTTP::Server::Response.new(io))
    handler.call(context)
    context.response.close
    io.rewind
    HTTP::Client::Response.from_io(io, ignore_body: true).headers
  end
end

describe "HEAD requests" do
  it "answers with the GET headers and no body, so the connection stays usable" do
    app = Azu::App.new
    app.router.get "/hello", HeadHello.new
    server = app.server([] of HTTP::Handler)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    begin
      client = HTTP::Client.new(address.address, address.port)
      head = client.head("/hello")
      head.status_code.should eq 200
      head.headers["Content-Length"]?.should eq "5"
      head.headers["Content-Type"]?.should eq "text/plain"

      client.get("/hello").body.should eq "hello"
      client.close
    ensure
      server.close
    end
  end

  it "writes the headers and nothing after them" do
    app = Azu::App.new
    app.router.get "/hello", HeadHello.new
    io = IO::Memory.new
    context = HTTP::Server::Context.new(HTTP::Request.new("HEAD", "/hello"), HTTP::Server::Response.new(io))

    app.dispatcher([] of HTTP::Handler).call(context)
    context.response.close

    io.to_s.should contain "Content-Length: 5"
    io.to_s.should end_with "\r\n\r\n"
  end

  it "goes through Handler::Compression as the GET does: same Content-Encoding, the compressed length" do
    app = Azu::App.new
    app.router.get "/long", HeadLong.new
    head, get = head_and_get(app.dispatcher([Azu::Handler::Compression.new] of HTTP::Handler), "/long", HTTP::Headers{"Accept-Encoding" => "gzip"})

    get["Content-Encoding"]?.should eq "gzip"
    head["Content-Encoding"]?.should eq "gzip"
    head["Content-Length"]?.should_not be_nil
    head["Content-Length"].to_i.should be < 1200
  end

  it "sends no body from a router used without an app" do
    router = Azu::Router.new
    router.get "/hello", HeadHello.new
    io = IO::Memory.new
    context = HTTP::Server::Context.new(HTTP::Request.new("HEAD", "/hello"), HTTP::Server::Response.new(io))
    router.process(context)
    context.response.close
    io.to_s.should contain "Content-Length: 5"
    io.to_s.should end_with "\r\n\r\n"
  end
end
