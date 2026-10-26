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
        client.get("/hello/").status_code.should eq 200
      end
    end
  end
end

# What SecurityHeaders passes the request to; it answers nothing, so the response keeps only the headers set before.
private class Answered
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
  end
end

# The response headers after `handler` ran on a response that already holds `preset`, as the default stack's does
# (RequestId sets X-Request-ID first).
private def headers_after(handler : Azu::Handler::SecurityHeaders, preset : HTTP::Headers) : Array({String, Array(String)})
  handler.next = Answered.new
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new))
  context.response.headers.merge!(preset)
  handler.call(context)
  context.response.headers.to_a
end

describe Azu::Handler::SecurityHeaders do
  it "adds its headers after the ones already set, with the default values" do
    headers_after(Azu::Handler::SecurityHeaders.new, HTTP::Headers{"X-Request-ID" => "req-1"}).should eq [
      {"X-Request-ID", ["req-1"]},
      {"X-Content-Type-Options", ["nosniff"]},
      {"X-Frame-Options", ["SAMEORIGIN"]},
      {"Referrer-Policy", ["strict-origin-when-cross-origin"]},
    ]
  end

  it "adds the configured values, the policy and HSTS" do
    handler = Azu::Handler::SecurityHeaders.new("DENY", "no-referrer", "default-src 'self'", hsts: true)

    headers_after(handler, HTTP::Headers{"X-Request-ID" => "req-1"}).should eq [
      {"X-Request-ID", ["req-1"]},
      {"X-Content-Type-Options", ["nosniff"]},
      {"X-Frame-Options", ["DENY"]},
      {"Referrer-Policy", ["no-referrer"]},
      {"Content-Security-Policy", ["default-src 'self'"]},
      {"Strict-Transport-Security", [Azu::Handler::SecurityHeaders::HSTS_VALUE]},
    ]
  end

  it "never overwrites a header already on the response, however it is spelled" do
    handler = Azu::Handler::SecurityHeaders.new(content_security_policy: "default-src 'self'", hsts: true)
    preset = HTTP::Headers{"x_frame_options" => "DENY", "content-security-policy" => "none", "STRICT-TRANSPORT-SECURITY" => "max-age=1"}

    headers_after(handler, preset).should eq [
      {"x_frame_options", ["DENY"]},
      {"content-security-policy", ["none"]},
      {"STRICT-TRANSPORT-SECURITY", ["max-age=1"]},
      {"X-Content-Type-Options", ["nosniff"]},
      {"Referrer-Policy", ["strict-origin-when-cross-origin"]},
    ]
  end

  it "refuses a value no response could carry when it is built, not on every request" do
    expect_raises(ArgumentError) { Azu::Handler::SecurityHeaders.new(content_security_policy: "default-src 'self'\r\nX-Injected: 1") }
    expect_raises(ArgumentError) { Azu::Handler::SecurityHeaders.new(frame_options: "DENY\n") }
  end

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
      client.get("/health/?probe=1").status_code.should eq 200
      response.headers["Cache-Control"].should eq "no-store"

      head = client.head("/health")
      head.status_code.should eq 200
      head.headers["Content-Length"].to_i.should eq response.body.bytesize
      head.body.should be_empty
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
