require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

describe "Security Integration" do
  describe "CSRF + CORS integration" do
    it "allows CORS preflight without CSRF token" do
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      csrf = Azu::Handler::CSRF.new
      final_handler, verify = create_next_handler(0)

      csrf.next = final_handler
      cors.next = csrf

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "Content-Type"
      context, io = create_context("OPTIONS", "/test", headers)

      cors.call(context)

      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_true
      verify.call
    end

    it "validates CSRF for POST with CORS" do
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      csrf = Azu::Handler::CSRF.new([] of String)
      final_handler, verify = create_next_handler(1)

      csrf.next = final_handler
      cors.next = csrf

      # First, get a token
      context1, io1 = create_context("GET", "/form")
      csrf.call(context1)
      cookie = context1.response.headers["Set-Cookie"]?

      # Now use it
      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Cookie"] = cookie.to_s if cookie
      headers["X-CSRF-TOKEN"] = cookie.to_s.split("=")[1].split(";")[0] if cookie
      context, io = create_context("POST", "/submit", headers)

      cors.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "IP Spoofing + Throttle integration" do
    it "validates IP before rate limiting" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      throttle = Azu::Handler::Throttle.new(60, 60, 10, [] of String, [] of String)
      final_handler, verify = create_next_handler(0)

      throttle.next = final_handler
      ip_spoofing.next = throttle

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1"  # Spoofed
      context, io = create_context("GET", "/test", headers)

      ip_spoofing.call(context)

      context.response.status_code.should eq(403)
      verify.call
      throttle.reset
    end

    it "rate limits after IP validation passes" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      throttle = Azu::Handler::Throttle.new(60, 60, 2, [] of String, [] of String)
      final_handler, verify = create_next_handler(2)

      throttle.next = final_handler
      ip_spoofing.next = throttle

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["REMOTE_ADDR"] = "192.168.1.1"

      # First 2 requests should pass
      2.times do
        context, io = create_context("GET", "/test", headers)
        ip_spoofing.call(context)
        get_response_body(context, io).should eq("OK")
      end

      # 3rd request should be throttled
      context, io = create_context("GET", "/test", headers)
      ip_spoofing.call(context)
      context.response.status_code.should eq(429)

      verify.call
      throttle.reset
    end
  end

  describe "Full security chain" do
    it "processes through all security handlers" do
      request_id = Azu::Handler::RequestId.new
      ip_spoofing = Azu::Handler::IpSpoofing.new
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      csrf = Azu::Handler::CSRF.new([] of String)
      throttle = Azu::Handler::Throttle.new(60, 60, 100, [] of String, [] of String)
      final_handler, verify = create_next_handler(1)

      throttle.next = final_handler
      csrf.next = throttle
      cors.next = csrf
      ip_spoofing.next = cors
      request_id.next = ip_spoofing

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["REMOTE_ADDR"] = "192.168.1.1"
      context, io = create_context("GET", "/test", headers)

      request_id.call(context)

      get_response_body(context, io).should eq("OK")
      context.response.headers["Access-Control-Allow-Origin"].should eq("https://example.com")
      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
      throttle.reset
    end

    it "blocks at first security violation" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      csrf = Azu::Handler::CSRF.new
      final_handler, verify = create_next_handler(0)

      csrf.next = final_handler
      cors.next = csrf
      ip_spoofing.next = cors

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      ip_spoofing.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "CORS + rate limiting" do
    it "applies rate limits with CORS headers" do
      cors = Azu::Handler::CORS.new(origins: ["https://example.com"])
      throttle = Azu::Handler::Throttle.new(60, 60, 1, [] of String, [] of String)
      final_handler, verify = create_next_handler(1)

      throttle.next = final_handler
      cors.next = throttle

      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["REMOTE_ADDR"] = "192.168.1.1"

      # First request
      context1, io1 = create_context("GET", "/test", headers)
      cors.call(context1)
      get_response_body(context1, io1).should eq("OK")

      # Second request should be blocked
      context2, io2 = create_context("GET", "/test", headers)
      cors.call(context2)
      context2.response.status_code.should eq(429)

      verify.call
      throttle.reset
    end

    it "whitelists CORS origins from throttling" do
      cors = Azu::Handler::CORS.new(origins: ["https://trusted.com"])
      throttle = Azu::Handler::Throttle.new(60, 60, 1, [] of String, ["192.168.1.1"])
      final_handler, verify = create_next_handler(5)

      throttle.next = final_handler
      cors.next = throttle

      headers = HTTP::Headers.new
      headers["Origin"] = "https://trusted.com"
      headers["REMOTE_ADDR"] = "192.168.1.1"

      # Should allow unlimited requests from whitelisted IP
      5.times do
        context, io = create_context("GET", "/test", headers)
        cors.call(context)
        get_response_body(context, io).should eq("OK")
      end

      verify.call
      throttle.reset
    end
  end

  describe "CSRF token validation in chain" do
    it "validates CSRF tokens through full chain" do
      request_id = Azu::Handler::RequestId.new
      cors = Azu::Handler::CORS.new(origins: ["*"])
      csrf = Azu::Handler::CSRF.new([] of String)
      final_handler, verify = create_next_handler(1)

      csrf.next = final_handler
      cors.next = csrf
      request_id.next = cors

      # Get token first
      context1, io1 = create_context("GET", "/form")
      csrf.call(context1)
      cookie = context1.response.headers["Set-Cookie"]?

      # Use token
      headers = HTTP::Headers.new
      headers["Cookie"] = cookie.to_s if cookie
      headers["X-CSRF-TOKEN"] = cookie.to_s.split("=")[1].split(";")[0] if cookie
      context, io = create_context("POST", "/submit", headers)

      request_id.call(context)

      get_response_body(context, io).should eq("OK")
      context.request.headers.has_key?("X-Request-ID").should be_true
      verify.call
    end
  end

  describe "origin validation with preflight" do
    it "validates origin in preflight request" do
      cors = Azu::Handler::CORS.new(origins: ["https://allowed.com"])
      csrf = Azu::Handler::CSRF.new
      final_handler, verify = create_next_handler(0)

      csrf.next = final_handler
      cors.next = csrf

      headers = HTTP::Headers.new
      headers["Origin"] = "https://allowed.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "Content-Type"
      context, io = create_context("OPTIONS", "/test", headers)

      cors.call(context)

      context.response.headers["Access-Control-Allow-Origin"].should eq("https://allowed.com")
      verify.call
    end

    it "blocks invalid origins in preflight" do
      cors = Azu::Handler::CORS.new(origins: ["https://allowed.com"])
      final_handler, verify = create_next_handler(0)
      cors.next = final_handler

      headers = HTTP::Headers.new
      headers["Origin"] = "https://evil.com"
      headers["Access-Control-Request-Method"] = "POST"
      headers["Access-Control-Request-Headers"] = "Content-Type"
      context, io = create_context("OPTIONS", "/test", headers)

      cors.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "rate limiting with whitelists/blacklists" do
    it "blocks blacklisted IPs before CORS" do
      throttle = Azu::Handler::Throttle.new(60, 60, 100, ["10.0.0.1"], [] of String)
      cors = Azu::Handler::CORS.new
      final_handler, verify = create_next_handler(0)

      cors.next = final_handler
      throttle.next = cors

      headers = HTTP::Headers.new
      headers["REMOTE_ADDR"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      throttle.call(context)

      context.response.status_code.should eq(429)
      verify.call
      throttle.reset
    end
  end

  describe "concurrent security checks" do
    it "handles concurrent requests through security chain" do
      cors = Azu::Handler::CORS.new(origins: ["*"])
      throttle = Azu::Handler::Throttle.new(60, 60, 100, [] of String, [] of String)
      final_handler, verify = create_next_handler(10)

      throttle.next = final_handler
      cors.next = throttle

      channel = Channel(Bool).new

      10.times do |i|
        spawn do
          headers = HTTP::Headers.new
          headers["Origin"] = "https://test.com"
          headers["REMOTE_ADDR"] = "192.168.1.#{i}"
          context, io = create_context("GET", "/test", headers)
          cors.call(context)
          channel.send(true)
        end
      end

      10.times { channel.receive }
      verify.call
      throttle.reset
    end
  end
end

