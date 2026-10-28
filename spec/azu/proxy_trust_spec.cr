require "../spec_helper"

private def proxy_context(headers : HTTP::Headers, peer : String? = "203.0.113.10")
  request = HTTP::Request.new("POST", "/submit", headers)
  request.remote_address = Socket::IPAddress.new(peer, 12345) if peer
  HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
end

private def with_proxy_config(proxies = [] of String, &)
  config = Azu::Configuration.new
  config.trusted_proxies = proxies
  Azu.with_scope(nil, config) { yield config }
end

describe "forwarded headers at security boundaries" do
  it "refuses a foreign CSRF origin even with a valid token and forged forwarded host" do
    with_proxy_config do
      handler = Azu::Handler::CSRF.new(secret_key: "proxy-trust-regression-secret")
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "accepted" }
      token = handler.token(proxy_context(HTTP::Headers.new))
      context = proxy_context(HTTP::Headers{
        "Host" => "app.example", "Origin" => "https://evil.example",
        "X-Forwarded-Host" => "evil.example", "X-Forwarded-Proto" => "https",
        "Cookie" => "csrf_token=#{token}", "X-CSRF-TOKEN" => token,
      })

      handler.call(context)

      context.response.status_code.should eq 403
    end
  end

  it "uses forwarded host and scheme only from an explicitly trusted IP peer" do
    with_proxy_config(["10.0.0.0/8"]) do
      handler = Azu::Handler::CSRF.new(secret_key: "proxy-trust-regression-secret")
      headers = HTTP::Headers{
        "Host" => "internal:4000", "Origin" => "https://app.example",
        "X-Forwarded-Host" => "app.example", "X-Forwarded-Proto" => "https",
      }
      handler.validate_origin(proxy_context(headers, "10.1.2.3")).should be_true
      handler.validate_origin(proxy_context(headers, "203.0.113.10")).should be_false
      handler.validate_origin(proxy_context(headers, nil)).should be_false
    end
  end

  it "does not let an untrusted peer mark a CSRF cookie secure" do
    with_proxy_config(["10.0.0.0/8"]) do
      handler = Azu::Handler::CSRF.new(secret_key: "proxy-trust-regression-secret", secure_cookies: true)
      headers = HTTP::Headers{"X-Forwarded-Proto" => "https"}
      untrusted = proxy_context(headers)
      trusted = proxy_context(headers, "10.1.2.3")
      handler.token(untrusted)
      handler.token(trusted)
      untrusted.response.cookies["csrf_token"].secure.should be_false
      trusted.response.cookies["csrf_token"].secure.should be_true
    end
  end

  it "ignores an untrusted forwarded scheme when deciding a WebSocket origin" do
    with_proxy_config(["10.0.0.0/8"]) do
      headers = HTTP::Headers{"Host" => "app.example", "Origin" => "https://app.example", "X-Forwarded-Proto" => "http"}
      Azu::Channel.origin_allowed?(proxy_context(headers).request).should be_true
      Azu::Channel.origin_allowed?(proxy_context(headers, "10.1.2.3").request).should be_false
    end
  end

  it "does not emit automatic HSTS for an untrusted or missing peer" do
    with_proxy_config(["10.0.0.0/8"]) do
      handler = Azu::Handler::SecurityHeaders.new(hsts: :auto)
      handler.next = ->(_context : HTTP::Server::Context) { }
      headers = HTTP::Headers{"X-Forwarded-Proto" => "https"}
      ["203.0.113.10", nil].each do |peer|
        context = proxy_context(headers, peer)
        handler.call(context)
        context.response.headers["Strict-Transport-Security"]?.should be_nil
      end
      trusted = proxy_context(headers, "10.1.2.3")
      handler.call(trusted)
      trusted.response.headers["Strict-Transport-Security"].should eq Azu::Handler::SecurityHeaders::HSTS_VALUE
    end
  end
end
