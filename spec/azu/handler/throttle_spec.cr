require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

class QuotaExceeded < Azu::Response::RateLimitError
  def initialize(retry_after : Int32? = nil)
    super(retry_after)
    @title = "Quota exhausted"
    @detail = "Upgrade your plan"
  end
end

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
      with_fake_clock do |clock|
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

        # Let the interval expire
        clock.advance(1.5.seconds)

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
      context.response.headers.has_key?("Retry-After").should be_true

      verify.call
      handler.reset
    end
  end

  describe "the refusal" do
    around_each do |example|
      Azu::Handler::Throttle::RefusalPages.clear
      example.run
      Azu::Handler::Throttle::RefusalPages.clear
    end

    refuse = ->(accept : String?, remote : String) do
      handler = Azu::Handler::Throttle.new(60, 60, 100, [remote], [] of String)
      handler.next = create_next_handler(0)[0]
      headers = HTTP::Headers.new
      headers["Accept"] = accept if accept
      context, io = create_context_with_remote_addr("GET", "/limited", remote, headers)
      handler.call(context)
      {context, get_response_body(context, io)}
    end

    it "answers a JSON client with the problem body, the Retry-After and the error id of the response" do
      context, body = refuse.call("application/json", "10.1.0.1")

      context.response.status_code.should eq 429
      context.response.headers["Content-Type"].should eq "application/json"
      context.response.headers["Retry-After"].should eq "0"
      problem = JSON.parse(body)
      problem["type"].as_s.should eq "about:blank"
      problem["title"].as_s.should eq "Rate Limit Exceeded"
      problem["status"].as_i.should eq 429
      problem["detail"].as_s.should eq "Rate limit exceeded. Retry after 0 seconds."
      problem["instance"].as_s.should eq "/limited"
      problem["error_id"].as_s.should eq context.response.headers["X-Error-ID"]
    end

    it "labels the body problem+json for a client that names it" do
      context, body = refuse.call("application/problem+json", "10.1.0.2")

      context.response.headers["Content-Type"].should eq "application/problem+json"
      JSON.parse(body)["status"].as_i.should eq 429
    end

    it "answers a plain-text and a missing Accept with text" do
      refuse.call("text/plain", "10.1.0.3")[0].response.headers["Content-Type"].should eq "text/plain"
      context, body = refuse.call(nil, "10.1.0.4")
      context.response.headers["Content-Type"].should eq "text/plain"
      body.should contain "Rate Limit Exceeded"
    end

    it "renders the HTML page once for refusals that read alike, and its error id is the header's" do
      first_context, first = refuse.call("text/html", "10.1.0.5")
      second_context, second = refuse.call("text/html", "10.1.0.6")

      first_context.response.headers["Content-Type"].should eq "text/html"
      first.should contain "Rate Limit Exceeded"
      first.should contain first_context.response.headers["X-Error-ID"]
      second.should eq first
      second_context.response.headers["X-Error-ID"].should eq first_context.response.headers["X-Error-ID"]
    end
  end

  describe "the cached HTML refusal" do
    around_each do |example|
      Azu::Handler::Throttle::RefusalPages.clear
      example.run
      Azu::Handler::Throttle::RefusalPages.clear
    end

    html_context = ->(remote : String) do
      headers = HTTP::Headers{"Accept" => "text/html"}
      context, io = create_context_with_remote_addr("GET", "/limited", remote, headers)
      {context, io}
    end

    refuse = ->(remote : String) do
      handler = Azu::Handler::Throttle.new(60, 60, 100, [remote], [] of String)
      handler.next = create_next_handler(0)[0]
      context, io = html_context.call(remote)
      handler.call(context)
      {context, get_response_body(context, io)}
    end

    it "is rendered once a second for Throttle's own refusals, with the error id of the page in the header" do
      with_fake_clock do |clock|
        first_context, first = refuse.call("10.2.0.1")
        second_context, second = refuse.call("10.2.0.2")

        first.should contain "Rate Limit Exceeded"
        first.should contain first_context.response.headers["X-Error-ID"]
        second.should eq first
        second_context.response.headers["X-Error-ID"].should eq first_context.response.headers["X-Error-ID"]

        clock.advance(1.5.seconds)
        third_context, third = refuse.call("10.2.0.3")
        third_context.response.headers["X-Error-ID"].should_not eq first_context.response.headers["X-Error-ID"]
        third.should_not eq first
      end
    end

    it "is kept apart per locale, so a request-dependent page is never served to another locale" do
      with_fake_clock do
        english = Azu::Helpers::I18n.with_locale("en") { refuse.call("10.2.0.4")[0].response.headers["X-Error-ID"] }
        other = Azu::Helpers::I18n.with_locale("es") { refuse.call("10.2.0.5")[0].response.headers["X-Error-ID"] }
        other.should_not eq english
      end
    end

    it "is rendered fresh every time in development" do
      with_fake_clock do
        with_azu_env(Azu::Environment::Development) do
          first = refuse.call("10.2.0.6")[0].response.headers["X-Error-ID"]
          second = refuse.call("10.2.0.7")[0].response.headers["X-Error-ID"]
          second.should_not eq first
        end
        Azu::Handler::Throttle::RefusalPages.size.should eq 0
      end
    end

    it "keeps a bounded number of pages" do
      with_fake_clock do
        templates = Azu.current_config.templates
        (Azu::Handler::Throttle::RefusalPages::MAX + 5).times do |seconds|
          Azu::Handler::Throttle::RefusalPages.fetch(templates, seconds, "en") { {"id", "<p>#{seconds}</p>"} }
        end
        Azu::Handler::Throttle::RefusalPages.size.should be <= Azu::Handler::Throttle::RefusalPages::MAX
      end
    end

    it "is never used for an error a user raised, which always renders its own text" do
      with_fake_clock do
        render = ->(error : Azu::Response::RateLimitError) do
          context, io = html_context.call("10.2.0.8")
          error.to_s(context)
          get_response_body(context, io)
        end

        first = render.call(Azu::Response::RateLimitError.new(5))
        mine = Azu::Response::RateLimitError.new(5)
        mine.detail = "Too many exports for acme-corp"
        mine.errors = ["acme-corp is over its plan"]
        second = render.call(mine)
        other = Azu::Response::RateLimitError.new(5)
        other.detail = "Too many exports for globex"
        third = render.call(other)

        second.should contain "Too many exports for acme-corp"
        second.should_not eq first
        third.should contain "Too many exports for globex"
        third.should_not contain "acme-corp"
      end
    end

    it "is never used for a subclass with its own title and detail" do
      with_fake_clock do
        quota = QuotaExceeded.new(5)
        context, io = html_context.call("10.2.0.9")
        Azu::Response::RateLimitError.new(5).to_s(html_context.call("10.2.0.10")[0]) # warm anything cached
        quota.to_s(context)
        body = get_response_body(context, io)
        body.should contain "Quota exhausted"
        body.should contain "Upgrade your plan"
      end
    end
  end

  describe "the refusal log line" do
    around_each do |example|
      Azu::Handler::Throttle::RefusalPages.clear
      example.run
    end

    refuse = ->(handler : Azu::Handler::Throttle, remote : String) do
      context, _ = create_context_with_remote_addr("GET", "/limited", remote)
      handler.call(context)
    end

    it "names the client address" do
      handler = Azu::Handler::Throttle.new(5, 900, 100, ["10.3.0.1"], [] of String, ::Log.for("throttle_line_spec"))
      handler.next = create_next_handler(0)[0]
      Log.capture("*") do |logs|
        refuse.call(handler, "10.3.0.1")
        logs.next(:warn, /GET \/limited -> 429 .*10\.3\.0\.1/)
      end
    end

    it "writes at most a few lines a second and then one summary of what it left out" do
      with_fake_clock do |clock|
        handler = Azu::Handler::Throttle.new(5, 900, 100, ["10.3.0.2"], [] of String, ::Log.for("throttle_line_spec"))
        handler.next = create_next_handler(0)[0]
        Log.capture("*") do |logs|
          30.times { refuse.call(handler, "10.3.0.2") }
          Azu::Handler::Throttle::LOG_PER_SECOND.times { logs.next(:warn, /-> 429/) }
          logs.empty

          clock.advance(1.1.seconds)
          refuse.call(handler, "10.3.0.2")
          logs.next(:warn, /suppressed #{30 - Azu::Handler::Throttle::LOG_PER_SECOND} similar/)
          logs.next(:warn, /-> 429/)
          logs.empty
        end
      end
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
    it "handles a request without a peer address gracefully" do
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

  describe "client identity" do
    # Real servers never send a REMOTE_ADDR header, and a client can send any value
    # for it, so only the peer address of the connection identifies a client.
    request_from = ->(ip : String, port : Int32, spoofed_header : String?) do
      headers = HTTP::Headers.new
      headers["REMOTE_ADDR"] = spoofed_header if spoofed_header
      context, _ = create_context("GET", "/test", headers)
      context.request.remote_address = Socket::IPAddress.new(ip, port)
      context
    end

    it "limits a client that rotates a spoofed REMOTE_ADDR header" do
      handler = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: 2, blacklist: [] of String, whitelist: [] of String)
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }

      statuses = %w(1.1.1.1 2.2.2.2 3.3.3.3).map do |spoofed|
        context = request_from.call("6.6.6.6", 4000, spoofed)
        handler.call(context)
        context.response.status_code
      end

      statuses.should eq([200, 200, 429])
    end

    it "does not let a client borrow a whitelisted address through the header" do
      handler = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: 1, blacklist: [] of String, whitelist: ["10.0.0.1"])
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }

      statuses = 2.times.map do
        context = request_from.call("6.6.6.6", 4000, "10.0.0.1")
        handler.call(context)
        context.response.status_code
      end.to_a

      statuses.should eq([200, 429])
    end

    it "keys a client by address, not by connection port" do
      handler = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: 1, blacklist: [] of String, whitelist: [] of String)
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }

      statuses = [4000, 4001].map do |port|
        context = request_from.call("5.5.5.5", port, nil)
        handler.call(context)
        context.response.status_code
      end

      statuses.should eq([200, 429])
    end

    it "keeps clients at different addresses apart" do
      handler = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: 1, blacklist: [] of String, whitelist: [] of String)
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }

      statuses = %w(7.7.7.7 7.7.7.7 8.8.8.8).map do |ip|
        context = request_from.call(ip, 4000, nil)
        handler.call(context)
        context.response.status_code
      end

      statuses.should eq([200, 429, 200])
    end
  end
end
