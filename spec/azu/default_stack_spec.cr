require "../spec_helper"
require "http/client"

private struct Hello
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << "hello world, hello world, hello world, hello world"
    context
  end
end

private struct Boom
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    raise "boom"
  end
end

private def serve(handlers : Array(HTTP::Handler), app : Azu::App = Azu::App.new, &)
  app.routes do
    get "/hello", Hello
    get "/boom", Boom
  end
  server = app.server(handlers)
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
  describe "#default_handlers" do
    it "builds the documented stack, with new instances every time" do
      app = Azu::App.new
      handlers = app.default_handlers

      handlers.map(&.class).should eq [
        Azu::Handler::RequestId, Azu::Handler::Logger, Azu::Handler::Rescuer,
        Azu::Handler::SecurityHeaders, Azu::Handler::Static,
      ]
      app.default_handlers.each_with_index { |handler, index| handler.should_not be handlers[index] }
    end

    it "serves routes with a request id and security headers, also on error pages" do
      app = Azu::App.new
      serve(app.default_handlers, app) do |client|
        ok = client.get("/hello")
        ok.status_code.should eq 200
        ok.headers["X-Request-ID"]?.should_not be_nil
        ok.headers["X-Content-Type-Options"].should eq "nosniff"
        ok.headers["X-Frame-Options"].should eq "SAMEORIGIN"

        failed = client.get("/boom", HTTP::Headers{"Accept" => "application/json"})
        failed.status_code.should eq 500
        failed.headers["X-Content-Type-Options"].should eq "nosniff"
        client.get("/missing").status_code.should eq 404
      end
    end
  end
end

describe Azu::Handler::SecurityHeaders do
  it "leaves a header the application set and only sends HSTS on request" do
    handler = Azu::Handler::SecurityHeaders.new(content_security_policy: "default-src 'self'", hsts: true)
    serve([handler] of HTTP::Handler) do |client|
      response = client.get("/hello")
      response.headers["Content-Security-Policy"].should eq "default-src 'self'"
      response.headers["Strict-Transport-Security"].should contain "max-age="
    end

    serve([Azu::Handler::SecurityHeaders.new] of HTTP::Handler) do |client|
      response = client.get("/hello")
      response.headers["Strict-Transport-Security"]?.should be_nil
      response.headers["Content-Security-Policy"]?.should be_nil
    end
  end
end

describe Azu::Handler::HealthCheck do
  it "answers 200 without reaching the router and passes other paths on" do
    serve([Azu::Handler::HealthCheck.new] of HTTP::Handler) do |client|
      response = client.get("/health")
      response.status_code.should eq 200
      JSON.parse(response.body)["status"].should eq "ok"
      client.get("/hello").body.should start_with "hello"
    end
  end

  it "answers 503 naming the failing checks, and counts a raising check as failing" do
    checks = {"up" => -> { true }, "down" => -> { false }, "broken" => -> { raise "x"; true }} of String => Azu::Handler::HealthCheck::Check
    serve([Azu::Handler::HealthCheck.new("/ready", checks)] of HTTP::Handler) do |client|
      response = client.get("/ready")
      response.status_code.should eq 503
      JSON.parse(response.body)["failing"].as_a.map(&.as_s).sort.should eq ["broken", "down"]
    end
  end
end

describe Azu::Handler::Compression do
  it "gzips for clients that accept it" do
    serve([Azu::Handler::Compression.new] of HTTP::Handler) do |client|
      response = client.get("/hello", HTTP::Headers{"Accept-Encoding" => "gzip"})
      response.headers["Content-Encoding"].should eq "gzip"
    end
  end
end
