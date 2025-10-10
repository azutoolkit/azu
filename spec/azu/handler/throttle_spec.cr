require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Handler::Throttle do
  describe "initialization" do
    it "initializes with default values" do
      handler = Azu::Handler::Throttle.new(
        interval: 5,
        duration: 900,
        threshold: 100,
        blacklist: [] of String,
        whitelist: [] of String
      )
      handler.should be_a(Azu::Handler::Throttle)
      # Properties are private getters, just test initialization succeeds
    end

    it "initializes with custom configuration" do
      handler = Azu::Handler::Throttle.new(
        interval: 10,
        duration: 300,
        threshold: 50,
        blacklist: ["1.1.1.1"],
        whitelist: ["2.2.2.2"]
      )
      handler.should be_a(Azu::Handler::Throttle)
      # Verify behavior through stats instead
      stats = handler.stats
      stats[:tracked_ips].should eq(0) # No requests yet
    end
  end

  describe "rate limiting" do
    it "allows requests below threshold" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 5,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(5)
      handler.next = next_handler

      5.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.1")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      verify.call
      handler.reset
    end

    it "blocks requests exceeding threshold" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 3,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(3)
      handler.next = next_handler

      # First 3 requests should succeed
      3.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.2")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      # 4th and 5th requests should be blocked
      2.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.2")
        handler.call(context)
        context.response.status_code.should eq(429)
        context.response.headers.has_key?("Retry-After").should be_true
      end

      verify.call
      handler.reset
    end

    it "tracks different IPs independently" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 2,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(4)
      handler.next = next_handler

      # IP 1: 2 requests (within limit)
      2.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.3")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      # IP 2: 2 requests (within limit)
      2.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.4")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      verify.call
      handler.reset
    end

    it "resets counter after interval expires" do
      handler = Azu::Handler::Throttle.new(
        interval: 1, # 1 second interval
        duration: 60,
        threshold: 2,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(4)
      handler.next = next_handler

      # Make 2 requests
      2.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.5")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      # Wait for interval to expire
      sleep 1.5.seconds

      # Should allow 2 more requests after reset
      2.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.1.5")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      verify.call
      handler.reset
    end
  end

  describe "blacklist" do
    it "blocks requests from blacklisted IPs immediately" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 100,
        blacklist: ["10.0.0.1"],
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      context, io = create_context_with_remote_addr("GET", "/test", "10.0.0.1")
      handler.call(context)

      context.response.status_code.should eq(429)
      verify.call
    end

    it "allows non-blacklisted IPs" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 100,
        blacklist: ["10.0.0.1"],
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context_with_remote_addr("GET", "/test", "10.0.0.2")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
      handler.reset
    end
  end

  describe "whitelist" do
    it "allows unlimited requests from whitelisted IPs" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 2,
        blacklist: [] of String,
        whitelist: ["172.16.0.1"]
      )
      next_handler, verify = create_next_handler(10)
      handler.next = next_handler

      # Make 10 requests (way above threshold)
      10.times do
        context, io = create_context_with_remote_addr("GET", "/test", "172.16.0.1")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      verify.call
      handler.reset
    end

    it "enforces limits on non-whitelisted IPs" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 2,
        blacklist: [] of String,
        whitelist: ["172.16.0.1"]
      )
      next_handler, verify = create_next_handler(2)
      handler.next = next_handler

      # Non-whitelisted IP should be limited
      2.times do
        context, io = create_context_with_remote_addr("GET", "/test", "172.16.0.2")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      # 3rd request should be blocked
      context, io = create_context_with_remote_addr("GET", "/test", "172.16.0.2")
      handler.call(context)
      context.response.status_code.should eq(429)

      verify.call
      handler.reset
    end
  end

  describe "response headers" do
    it "sets proper headers when blocking request" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 1,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      # First request succeeds
      context, io = create_context_with_remote_addr("GET", "/test", "192.168.2.1")
      handler.call(context)
      get_response_body(context, io).should eq("OK")

      # Second request is blocked
      context, io = create_context_with_remote_addr("GET", "/test", "192.168.2.1")
      handler.call(context)

      context.response.status_code.should eq(429)
      context.response.headers["Content-Type"].should eq("text/plain")
      context.response.headers["Content-Length"].should eq("0")
      context.response.headers.has_key?("Retry-After").should be_true

      verify.call
      handler.reset
    end
  end

  describe "statistics" do
    it "tracks number of IPs being monitored" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 100,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(3)
      handler.next = next_handler

      # Make requests from 3 different IPs
      ["192.168.3.1", "192.168.3.2", "192.168.3.3"].each do |ip|
        context, io = create_context_with_remote_addr("GET", "/test", ip)
        handler.call(context)
      end

      stats = handler.stats
      stats[:tracked_ips].should eq(3)

      verify.call
      handler.reset
    end

    it "tracks blocked IPs" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 1,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(2)
      handler.next = next_handler

      # Block 2 IPs
      ["192.168.4.1", "192.168.4.2"].each do |ip|
        2.times do |i|
          context, io = create_context_with_remote_addr("GET", "/test", ip)
          handler.call(context)
          if i == 0
            get_response_body(context, io).should eq("OK")
          end
        end
      end

      stats = handler.stats
      stats[:blocked_ips].should eq(2)

      verify.call
      handler.reset
    end
  end

  describe "reset" do
    it "clears all tracked IPs" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 1,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(2)
      handler.next = next_handler

      # Make a request to start tracking
      context, io = create_context_with_remote_addr("GET", "/test", "192.168.5.1")
      handler.call(context)

      # Reset handler
      handler.reset

      # Should be able to make request again
      context, io = create_context_with_remote_addr("GET", "/test", "192.168.5.1")
      handler.call(context)
      get_response_body(context, io).should eq("OK")

      verify.call
      handler.reset
    end
  end

  describe "concurrent requests" do
    it "handles concurrent requests safely" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 10,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(10)
      handler.next = next_handler

      # Spawn 10 concurrent requests
      channel = Channel(Nil).new
      10.times do
        spawn do
          context, io = create_context_with_remote_addr("GET", "/test", "192.168.6.1")
          handler.call(context)
          channel.send(nil)
        end
      end

      # Wait for all requests to complete
      10.times { channel.receive }

      verify.call
      handler.reset
    end
  end

  describe "edge cases" do
    it "handles missing REMOTE_ADDR header gracefully" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 100,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      # Should still work with "unknown" as the remote address
      get_response_body(context, io).should eq("OK")
      verify.call
      handler.reset
    end

    it "handles very high thresholds" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 1000,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(100)
      handler.next = next_handler

      100.times do
        context, io = create_context_with_remote_addr("GET", "/test", "192.168.7.1")
        handler.call(context)
        get_response_body(context, io).should eq("OK")
      end

      verify.call
      handler.reset
    end

    it "handles zero threshold gracefully" do
      handler = Azu::Handler::Throttle.new(
        interval: 60,
        duration: 60,
        threshold: 0,
        blacklist: [] of String,
        whitelist: [] of String
      )
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      context, io = create_context_with_remote_addr("GET", "/test", "192.168.8.1")
      handler.call(context)

      # Should be blocked immediately
      context.response.status_code.should eq(429)
      verify.call
      handler.reset
    end
  end
end
