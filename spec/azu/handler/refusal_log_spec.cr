require "../../spec_helper"
require "../../support/integration_helpers"
require "log/spec"

include IntegrationHelpers

# The handlers that answer a refusal themselves (they never raise to the Rescuer) log it the way the Rescuer logs a 4xx:
# one line, at the level of the status (403 and 429 warn, 401 info), with the request and the reason, and no exception.
describe "refusals written by handlers" do
  it "logs a CSRF refusal once, at warn, with the request and the reason" do
    handler = Azu::Handler::CSRF.new
    handler.next = create_next_handler(0)[0]
    context, _ = create_context("POST", "/forms/submit")

    Log.capture("*") do |logs|
      handler.call(context)
      logs.next(:warn, /POST \/forms\/submit -> 403 Authorization Failed: CSRF token validation failed/)
      logs.entry.exception.should be_nil
      logs.empty
    end
    context.response.status_code.should eq 403
  end

  it "logs an IpSpoofing refusal once, at warn" do
    handler = Azu::Handler::IpSpoofing.new
    handler.next = create_next_handler(0)[0]
    headers = HTTP::Headers{"X-Forwarded-For" => "1.1.1.1", "X-Client-IP" => "2.2.2.2"}
    context, _ = create_context("GET", "/spoofed", headers)

    Log.capture("*") do |logs|
      handler.call(context)
      logs.next(:warn, /GET \/spoofed -> 403/)
      logs.empty
    end
    context.response.status_code.should eq 403
  end

  it "logs a refused CORS origin and a refused preflight once each, at warn" do
    handler = Azu::Handler::CORS.new(origins: ["https://example.com"], methods: ["POST"], headers: ["Content-Type"])
    handler.next = create_next_handler(0)[0]

    Log.capture("*") do |logs|
      origin, _ = create_context("GET", "/data", HTTP::Headers{"Origin" => "https://evil.test"})
      handler.call(origin)
      logs.next(:warn, /GET \/data -> 403/)
      logs.empty

      preflight, _ = create_context("OPTIONS", "/data", HTTP::Headers{"Origin" => "https://example.com", "Access-Control-Request-Method" => "DELETE", "Access-Control-Request-Headers" => "Content-Type"})
      handler.call(preflight)
      logs.next(:warn, /OPTIONS \/data -> 403/)
      logs.empty
    end
  end

  it "logs a Throttle refusal once per refused request, at warn" do
    handler = Azu::Handler::Throttle.new(5, 900, 100, ["10.0.0.1"], [] of String, ::Log.for("refusal_log_spec"))
    handler.next = create_next_handler(0)[0]
    context, _ = create_context_with_remote_addr("GET", "/limited", "10.0.0.1")

    Log.capture("*") do |logs|
      handler.call(context)
      logs.next(:warn, /GET \/limited -> 429 Rate Limit Exceeded/)
      logs.empty
    end
    context.response.status_code.should eq 429
  end
end
