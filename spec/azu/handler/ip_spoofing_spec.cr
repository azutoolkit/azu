require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::IpSpoofing do
  describe "initialization" do
    it "initializes successfully" do
      handler = Azu::Handler::IpSpoofing.new
      handler.should be_a(Azu::Handler::IpSpoofing)
    end
  end

  describe "requests without X-Forwarded-For" do
    it "allows requests without X-Forwarded-For header" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "passes through normal requests" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["User-Agent"] = "Test"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "valid X-Forwarded-For requests" do
    it "allows requests with single IP in X-Forwarded-For" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "allows requests with multiple IPs in X-Forwarded-For" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1, 172.16.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "handles X-Forwarded-For with spaces" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1,  10.0.0.1,   172.16.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "X-Client-IP validation" do
    it "allows matching X-Client-IP" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1"
      headers["X-Client-IP"] = "192.168.1.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "blocks non-matching X-Client-IP" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1"
      headers["X-Client-IP"] = "172.16.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "accepts X-Client-IP from middle of chain" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1, 172.16.0.1"
      headers["X-Client-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "X-Real-IP validation" do
    it "allows matching X-Real-IP" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1"
      headers["X-Real-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "blocks non-matching X-Real-IP" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1"
      headers["X-Real-IP"] = "172.16.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "multiple header validation" do
    it "validates both X-Client-IP and X-Real-IP when present" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1, 172.16.0.1"
      headers["X-Client-IP"] = "192.168.1.1"
      headers["X-Real-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "blocks if X-Client-IP is invalid even if X-Real-IP is valid" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1"
      headers["X-Client-IP"] = "172.16.0.1" # Invalid
      headers["X-Real-IP"] = "192.168.1.1"  # Valid
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "blocks if X-Real-IP is invalid even if X-Client-IP is valid" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 10.0.0.1"
      headers["X-Client-IP"] = "192.168.1.1" # Valid
      headers["X-Real-IP"] = "172.16.0.1"    # Invalid
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end

  describe "response format" do
    it "sets proper headers when blocking" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      context.response.headers["Content-Type"].should eq("text/plain")
      context.response.headers["Content-Length"].should eq("0")
      verify.call
    end

    it "closes response when blocking" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Real-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      context.response.closed?.should be_true
      verify.call
    end
  end

  describe "security scenarios" do
    it "blocks IP spoofing attempt" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      # Attacker trying to spoof IP
      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1" # Doesn't match forwarded chain
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "blocks complex spoofing attempt" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 192.168.1.2"
      headers["X-Client-IP"] = "10.0.0.1"
      headers["X-Real-IP"] = "172.16.0.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end

    it "allows legitimate proxy chain" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "203.0.113.1, 192.168.1.1, 10.0.0.1"
      headers["X-Client-IP"] = "203.0.113.1"
      headers["X-Real-IP"] = "203.0.113.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "edge cases" do
    it "handles empty X-Forwarded-For" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = ""
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "handles whitespace-only X-Forwarded-For" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "   "
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "handles IPv6 addresses" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "2001:db8::1, 192.168.1.1"
      headers["X-Client-IP"] = "2001:db8::1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "handles mixed IPv4 and IPv6" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1, 2001:db8::1, 10.0.0.1"
      headers["X-Real-IP"] = "2001:db8::1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "handles single IP with X-Client-IP" do
      handler = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "192.168.1.1"
      context, io = create_context("GET", "/test", headers)

      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end
  end

  describe "handler chain integration" do
    it "works with other security handlers" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      cors = Azu::Handler::CORS.new
      next_handler, verify = create_next_handler(1)

      cors.next = next_handler
      ip_spoofing.next = cors

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      context, io = create_context("GET", "/test", headers)

      ip_spoofing.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "blocks before reaching other handlers" do
      ip_spoofing = Azu::Handler::IpSpoofing.new
      next_handler, verify = create_next_handler(0)
      ip_spoofing.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Forwarded-For"] = "192.168.1.1"
      headers["X-Client-IP"] = "10.0.0.1"
      context, io = create_context("GET", "/test", headers)

      ip_spoofing.call(context)

      context.response.status_code.should eq(403)
      verify.call
    end
  end
end
