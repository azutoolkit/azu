require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

private JSON_CLIENT = HTTP::Headers{"Accept" => "application/json"}

# The refusals handlers write themselves answer a JSON client with the problem document of Response::Error, and any
# other client with the text body, as every other error does.
describe "error bodies written by handlers" do
  it "answers a failed CSRF check with a JSON problem" do
    handler = Azu::Handler::CSRF.new
    handler.next = ->(_context : HTTP::Server::Context) { }
    context, io = create_context("POST", "/forms/submit", JSON_CLIENT)
    handler.call(context)

    context.response.status_code.should eq 403
    context.response.headers["Content-Type"].should eq "application/json"
    body = JSON.parse(get_response_body(context, io))
    body["status"].should eq 403
    body["detail"].should eq "CSRF token validation failed"
    body["instance"].should eq "/forms/submit"
  end

  it "answers a throttled request with a JSON problem and keeps Retry-After" do
    handler = Azu::Handler::Throttle.new(interval: 10, duration: 60, threshold: 1, blacklist: [] of String, whitelist: [] of String)
    handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
    first, _ = create_context_with_remote_addr("GET", "/t", "192.168.77.1", JSON_CLIENT)
    handler.call(first)
    context, io = create_context_with_remote_addr("GET", "/t", "192.168.77.1", JSON_CLIENT)
    handler.call(context)

    context.response.status_code.should eq 429
    context.response.headers["Retry-After"]?.should_not be_nil
    context.response.headers["Content-Type"].should eq "application/json"
    JSON.parse(get_response_body(context, io))["status"].should eq 429
    handler.reset
  end

  it "answers an invalid static path and a refused method with JSON problems" do
    with_temp_file("content", "test.txt") do |dir, _|
      handler = Azu::Handler::Static.new(dir, fallthrough: false)

      context, io = create_context("GET", "/test%00.txt", JSON_CLIENT)
      handler.call(context)
      context.response.status_code.should eq 400
      JSON.parse(get_response_body(context, io))["detail"].should eq "Invalid path"

      context, io = create_context("POST", "/test.txt", JSON_CLIENT)
      handler.call(context)
      context.response.status_code.should eq 405
      context.response.headers["Allow"].should eq "GET, HEAD"
      JSON.parse(get_response_body(context, io))["status"].should eq 405
    end
  end

  it "answers a refused origin with a JSON problem" do
    handler = Azu::Handler::CORS.new(origins: ["https://example.com"])
    handler.next = ->(_context : HTTP::Server::Context) { }
    headers = HTTP::Headers{"Accept" => "application/json", "Origin" => "https://evil.com"}
    context, io = create_context("GET", "/test", headers)
    handler.call(context)

    context.response.status_code.should eq 403
    JSON.parse(get_response_body(context, io))["title"].should eq "Authorization Failed"
  end

  it "answers a spoofed forwarding header with a JSON problem" do
    handler = Azu::Handler::IpSpoofing.new
    handler.next = ->(_context : HTTP::Server::Context) { }
    headers = HTTP::Headers{"Accept" => "application/json", "X-Forwarded-For" => "192.168.1.1", "X-Client-IP" => "10.0.0.1"}
    context, io = create_context("GET", "/test", headers)
    handler.call(context)

    context.response.status_code.should eq 403
    JSON.parse(get_response_body(context, io))["status"].should eq 403
  end
end
