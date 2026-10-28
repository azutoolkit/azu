require "../spec_helper"

# Helper method to create HTTP context
def create_context(method = "GET", path = "/", headers = HTTP::Headers.new, body = nil)
  request = HTTP::Request.new(method, path, headers, body)
  if headers.has_key?("X-Forwarded-Proto") || headers.has_key?("X-Forwarded-Host")
    request.remote_address = Socket::IPAddress.new("127.0.0.1", 12345)
  end
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  {context, io}
end

# Helper method to create a mock next handler
def create_next_handler(expected_calls = 1)
  call_count = 0
  next_handler = ->(context : HTTP::Server::Context) {
    call_count += 1
    context.response.print "OK"
  }
  {next_handler, -> { call_count.should eq(expected_calls) }}
end

# A POST carrying a valid token of `handler` in the header and the cookie: what a check refuses is not the token.
def signed_post(path : String, headers : HTTP::Headers, handler : Azu::Handler::CSRF)
  get_context, _ = create_context("GET", "/")
  token = handler.token(get_context)
  headers["X-CSRF-TOKEN"] = token
  headers["Cookie"] = "csrf_token=#{token}"
  create_context("POST", path, headers)
end

# Helper to read response output
def get_response_body(context, io)
  context.response.close
  io.rewind
  full_response = io.gets_to_end

  # Extract body from HTTP response (after the empty line that separates headers from body)
  if body_start = full_response.index("\r\n\r\n")
    full_response[(body_start + 4)..]
  elsif body_start = full_response.index("\n\n")
    full_response[(body_start + 2)..]
  else
    full_response
  end
end

describe Azu::Handler::CSRF do
  # These fixtures model an app behind its configured loopback proxy. Untrusted peers are covered in proxy_trust_spec.
  around_each do |example|
    config = Azu::Configuration.new
    config.trusted_proxies = ["127.0.0.1"]
    Azu.with_scope(nil, config) { example.run }
  end

  # Reset CSRF configuration before each test
  before_each do
    Azu::Handler::CSRF.strategy = Azu::Handler::CSRF::Strategy::SignedDoubleSubmit
    Azu::Handler::CSRF.secret_key = "test_secret_key_for_testing_purposes_only"
    Azu::Handler::CSRF.cookie_name = "csrf_token"
    Azu::Handler::CSRF.header_name = "X-CSRF-TOKEN"
    Azu::Handler::CSRF.param_name = "_csrf"
    Azu::Handler::CSRF.cookie_max_age = 86400
    Azu::Handler::CSRF.secure_cookies = false # For testing
  end

  describe "initialization" do
    it "initializes with default values" do
      handler = Azu::Handler::CSRF.new
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with skip routes" do
      skip_routes = ["/api/", "/webhook/"]
      handler = Azu::Handler::CSRF.new(skip_routes)
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "generates secret key if not set" do
      Azu::Handler::CSRF.reset_default!
      Azu::Handler::CSRF.secret_key = ""
      handler = Azu::Handler::CSRF.new
      # Secret key is now generated automatically during initialization
      handler.secret_key.should_not be_empty
    end
  end

  describe "safe method detection" do
    it "allows GET requests without CSRF protection" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify_calls.call
    end

    it "allows HEAD requests without CSRF protection" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("HEAD", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify_calls.call
    end

    it "allows OPTIONS requests without CSRF protection" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("OPTIONS", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify_calls.call
    end
  end

  describe "route skipping" do
    it "skips CSRF protection for configured routes" do
      skip_routes = ["/api/", "/webhook/"]
      handler = Azu::Handler::CSRF.new(skip_routes)
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("POST", "/api/users")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify_calls.call
    end

    it "enforces CSRF protection for non-skipped routes" do
      skip_routes = ["/api/"]
      handler = Azu::Handler::CSRF.new(skip_routes)
      next_handler, verify_calls = create_next_handler(0)
      handler.next = next_handler

      context, io = create_context("POST", "/forms/submit")
      handler.call(context)

      context.response.status.should eq(HTTP::Status::FORBIDDEN)
      get_response_body(context, io).should contain("CSRF token validation failed")
      verify_calls.call
    end
  end

  describe "requests that look like AJAX or form posts" do
    # A cross-site form can send any of these Content-Types and a caller can always
    # add X-Requested-With, so neither is proof that a request is same-origin.
    {% for content_type in %w(application/x-www-form-urlencoded multipart/form-data text/plain application/json) %}
      it "rejects a {{content_type.id}} POST without a token" do
        handler = Azu::Handler::CSRF.new
        next_handler, verify_calls = create_next_handler(0)
        handler.next = next_handler

        headers = HTTP::Headers{"Content-Type" => "{{content_type.id}}"}
        context, _ = create_context("POST", "/api/data", headers)
        handler.call(context)

        context.response.status.should eq(HTTP::Status::FORBIDDEN)
        verify_calls.call
      end
    {% end %}

    it "rejects an X-Requested-With POST without a token" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(0)
      handler.next = next_handler

      headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
      context, _ = create_context("POST", "/api/data", headers)
      handler.call(context)

      context.response.status.should eq(HTTP::Status::FORBIDDEN)
      verify_calls.call
    end

    it "accepts a JSON POST that carries a valid token header" do
      Azu::Handler::CSRF.use_signed_double_submit!
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      get_context, _ = create_context("GET", "/")
      token = Azu::Handler::CSRF.token(get_context)

      headers = HTTP::Headers{
        "Content-Type" => "application/json",
        "X-CSRF-TOKEN" => token,
        "Cookie"       => "csrf_token=#{token}",
      }
      context, io = create_context("POST", "/api/data", headers)
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify_calls.call
    end
  end

  describe "token generation" do
    describe "signed double submit strategy" do
      it "generates valid signed tokens" do
        Azu::Handler::CSRF.use_signed_double_submit!
        context, _ = create_context("GET", "/")

        token = Azu::Handler::CSRF.token(context)

        token.should_not be_empty
        token.split(":").size.should eq(3) # base_token:timestamp:signature
      end

      it "sets cookie when generating token" do
        Azu::Handler::CSRF.use_signed_double_submit!
        context, _ = create_context("GET", "/")

        token = Azu::Handler::CSRF.token(context)

        context.response.cookies.size.should eq(1)
        cookie = context.response.cookies.first
        cookie.name.should eq("csrf_token")
        cookie.value.should eq(token)
      end
    end

    describe "synchronizer token strategy" do
      it "generates tokens and stores in cookie" do
        Azu::Handler::CSRF.use_synchronizer_token!
        context, _ = create_context("GET", "/")

        token = Azu::Handler::CSRF.token(context)

        token.should_not be_empty
        context.response.cookies.size.should eq(1)
        context.response.cookies.first.value.should eq(token)
      end

      it "reuses existing token from cookie" do
        Azu::Handler::CSRF.use_synchronizer_token!
        existing_token = "existing_token_value"

        headers = HTTP::Headers.new
        headers["Cookie"] = "csrf_token=#{existing_token}"
        context, _ = create_context("GET", "/", headers)

        token = Azu::Handler::CSRF.token(context)

        token.should eq(existing_token)
        context.response.cookies.size.should eq(0) # No new cookie set
      end
    end

    describe "double submit strategy" do
      it "generates simple tokens" do
        Azu::Handler::CSRF.use_double_submit!
        context, _ = create_context("GET", "/")

        token = Azu::Handler::CSRF.token(context)

        token.should_not be_empty
        context.response.cookies.size.should eq(1)
        context.response.cookies.first.value.should eq(token)
      end
    end
  end

  describe "HTML helper methods" do
    it "generates hidden input tag" do
      context, _ = create_context("GET", "/")

      tag = Azu::Handler::CSRF.tag(context)

      tag.should contain(%Q(<input type="hidden"))
      tag.should contain(%Q(name="_csrf"))
      tag.should contain(%Q(value="))
    end

    it "generates meta tag" do
      context, _ = create_context("GET", "/")

      metatag = Azu::Handler::CSRF.metatag(context)

      metatag.should contain(%Q(<meta name="_csrf"))
      metatag.should contain(%Q(content="))
    end
  end

  describe "token validation" do
    describe "signed double submit validation" do
      it "validates correct tokens" do
        Azu::Handler::CSRF.use_signed_double_submit!
        handler = Azu::Handler::CSRF.new
        next_handler, verify_calls = create_next_handler(1)
        handler.next = next_handler

        # Generate token first
        get_context, _ = create_context("GET", "/")
        token = Azu::Handler::CSRF.token(get_context)

        # Use token in POST request
        headers = HTTP::Headers.new
        headers["X-CSRF-TOKEN"] = token
        headers["Cookie"] = "csrf_token=#{token}"
        context, io = create_context("POST", "/submit", headers)

        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify_calls.call
      end

      it "rejects invalid tokens" do
        Azu::Handler::CSRF.use_signed_double_submit!
        handler = Azu::Handler::CSRF.new
        next_handler, verify_calls = create_next_handler(0)
        handler.next = next_handler

        headers = HTTP::Headers.new
        headers["X-CSRF-TOKEN"] = "invalid_token"
        headers["Cookie"] = "csrf_token=invalid_token"
        context, _ = create_context("POST", "/submit", headers)

        handler.call(context)

        context.response.status.should eq(HTTP::Status::FORBIDDEN)
        verify_calls.call
      end
    end

    describe "synchronizer token validation" do
      it "validates matching tokens" do
        Azu::Handler::CSRF.use_synchronizer_token!
        handler = Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken)
        next_handler, verify_calls = create_next_handler(1)
        handler.next = next_handler

        token = "test_token_value"
        headers = HTTP::Headers.new
        headers["X-CSRF-TOKEN"] = token
        headers["Cookie"] = "csrf_token=#{token}"
        context, io = create_context("POST", "/submit", headers)

        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify_calls.call
      end

      it "rejects missing cookie token" do
        Azu::Handler::CSRF.use_synchronizer_token!
        handler = Azu::Handler::CSRF.new
        next_handler, verify_calls = create_next_handler(0)
        handler.next = next_handler

        headers = HTTP::Headers.new
        headers["X-CSRF-TOKEN"] = "test_token"
        context, _ = create_context("POST", "/submit", headers)

        handler.call(context)

        context.response.status.should eq(HTTP::Status::FORBIDDEN)
        verify_calls.call
      end
    end

    describe "double submit validation" do
      it "validates matching tokens" do
        Azu::Handler::CSRF.use_double_submit!
        handler = Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::DoubleSubmit)
        next_handler, verify_calls = create_next_handler(1)
        handler.next = next_handler

        token = "test_token_value"
        headers = HTTP::Headers.new
        headers["X-CSRF-TOKEN"] = token
        headers["Cookie"] = "csrf_token=#{token}"
        context, io = create_context("POST", "/submit", headers)

        handler.call(context)

        get_response_body(context, io).should eq("OK")
        verify_calls.call
      end
    end
  end

  describe "configuration" do
    it "configures strategy" do
      Azu::Handler::CSRF.use_synchronizer_token!
      Azu::Handler::CSRF.strategy.should eq(Azu::Handler::CSRF::Strategy::SynchronizerToken)

      Azu::Handler::CSRF.use_signed_double_submit!
      Azu::Handler::CSRF.strategy.should eq(Azu::Handler::CSRF::Strategy::SignedDoubleSubmit)

      Azu::Handler::CSRF.use_double_submit!
      Azu::Handler::CSRF.strategy.should eq(Azu::Handler::CSRF::Strategy::DoubleSubmit)
    end

    it "configures custom names" do
      Azu::Handler::CSRF.configure do |config|
        config.cookie_name = "custom_csrf"
        config.header_name = "X-Custom-CSRF"
        config.param_name = "custom_csrf_param"
      end

      Azu::Handler::CSRF.cookie_name.should eq("custom_csrf")
      Azu::Handler::CSRF.header_name.should eq("X-Custom-CSRF")
      Azu::Handler::CSRF.param_name.should eq("custom_csrf_param")
    end
  end

  describe "error handling" do
    it "raises InvalidTokenError for invalid tokens" do
      expect_raises(Azu::Handler::CSRF::InvalidTokenError) do
        raise Azu::Handler::CSRF::InvalidTokenError.new
      end
    end

    it "creates InvalidTokenError with custom message" do
      error = Azu::Handler::CSRF::InvalidTokenError.new("Custom error message")
      error.message.should eq("Custom error message")
    end
  end

  describe "origin validation" do
    it "validates matching origins" do
      headers = HTTP::Headers.new
      headers["Origin"] = "http://example.com"
      headers["Host"] = "example.com"
      context, _ = create_context("POST", "/", headers)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_true
    end

    it "rejects mismatched origins" do
      headers = HTTP::Headers.new
      headers["Origin"] = "http://evil.com"
      headers["Host"] = "example.com"
      context, _ = create_context("POST", "/", headers)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_false
    end

    it "validates referer when origin is missing" do
      headers = HTTP::Headers.new
      headers["Referer"] = "http://example.com/page"
      headers["Host"] = "example.com"

      # Create request with proper host setup
      request = HTTP::Request.new("POST", "/", headers)
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_true
    end

    it "matches whatever way the default port is written" do
      {"http://example.com:80/page", "http://example.com/page"}.each do |referer|
        context, _ = create_context("POST", "/", HTTP::Headers{"Referer" => referer, "Host" => "example.com"})
        Azu::Handler::CSRF.validate_origin(context).should be_true
      end
      context, _ = create_context("POST", "/", HTTP::Headers{"Origin" => "http://example.com:80", "Host" => "example.com"})
      Azu::Handler::CSRF.validate_origin(context).should be_true
      context, _ = create_context("POST", "/", HTTP::Headers{"Referer" => "https://example.com/p", "Host" => "example.com", "X-Forwarded-Proto" => "https"})
      Azu::Handler::CSRF.validate_origin(context).should be_true
    end

    it "rejects another port, another scheme and a request without Host" do
      context, _ = create_context("POST", "/", HTTP::Headers{"Referer" => "http://example.com:8080/", "Host" => "example.com"})
      Azu::Handler::CSRF.validate_origin(context).should be_false
      context, _ = create_context("POST", "/", HTTP::Headers{"Referer" => "https://example.com/", "Host" => "example.com", "X-Forwarded-Proto" => "http"})
      Azu::Handler::CSRF.validate_origin(context).should be_false
      # Without a scheme hint (no TLS here, no X-Forwarded-Proto) the host passes under either scheme
      context, _ = create_context("POST", "/", HTTP::Headers{"Referer" => "https://example.com/", "Host" => "example.com"})
      Azu::Handler::CSRF.validate_origin(context).should be_true
      context, _ = create_context("POST", "/", HTTP::Headers{"Origin" => "http://example.com"})
      Azu::Handler::CSRF.validate_origin(context).should be_false
    end

    it "handles HTTPS with X-Forwarded-Proto" do
      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Host"] = "example.com"
      headers["X-Forwarded-Proto"] = "https"
      context, _ = create_context("POST", "/", headers)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_true
    end
  end

  describe "the origin check" do
    it "refuses a request from another origin, however valid its token" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(0)
      handler.next = next_handler
      context, io = signed_post("/submit", HTTP::Headers{"Host" => "example.com", "Origin" => "https://evil.example"}, handler)

      handler.call(context)

      context.response.status_code.should eq 403
      get_response_body(context, io).should contain "origin"
      verify_calls.call
    end

    it "refuses a request whose Referer is another site when there is no Origin" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(0)
      handler.next = next_handler
      context, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com", "Referer" => "http://evil.example/page"}, handler)

      handler.call(context)

      context.response.status_code.should eq 403
      verify_calls.call
    end

    it "passes a request from the same origin, behind a proxy too" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(2)
      handler.next = next_handler

      same, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com", "Origin" => "http://example.com"}, handler)
      handler.call(same)
      same.response.status_code.should eq 200

      forwarded = HTTP::Headers{"Host" => "app-1.internal:3000", "X-Forwarded-Host" => "example.com", "X-Forwarded-Proto" => "https", "Origin" => "https://example.com"}
      proxied, _ = signed_post("/submit", forwarded, handler)
      handler.call(proxied)
      proxied.response.status_code.should eq 200
      verify_calls.call
    end

    it "checks the token alone when the request names no origin, so API clients are not affected" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler
      context, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com"}, handler)

      handler.call(context)

      context.response.status_code.should eq 200
      verify_calls.call
    end

    it "refuses the origins that name nobody: null, empty, or unparseable" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(0)
      handler.next = next_handler

      ["null", "", "example.com", "evil.example, http://example.com"].each do |origin|
        context, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com", "Origin" => origin}, handler)
        handler.call(context)
        context.response.status_code.should eq(403), "Origin #{origin.inspect} was accepted"
      end
      verify_calls.call
    end

    it "compares origins by scheme, host and effective port" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(4)
      handler.next = next_handler

      [
        {"example.com", "http://example.com:80"},
        {"example.com:8080", "http://example.com:8080"},
        {"[::1]:3000", "http://[::1]:3000"},
        {"example.com", "https://EXAMPLE.com"}, # the scheme is unknown without TLS or X-Forwarded-Proto: either passes
      ].each do |host, origin|
        context, _ = signed_post("/submit", HTTP::Headers{"Host" => host, "Origin" => origin}, handler)
        handler.call(context)
        context.response.status_code.should eq(200), "Origin #{origin} was refused for Host #{host}"
      end
      verify_calls.call

      other_port, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com:8080", "Origin" => "http://example.com:9090"}, handler)
      handler.call(other_port)
      other_port.response.status_code.should eq 403

      wrong_scheme, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com", "X-Forwarded-Proto" => "https", "Origin" => "http://example.com"}, handler)
      handler.call(wrong_scheme)
      wrong_scheme.response.status_code.should eq 403
    end

    it "takes the origin of a same-site Referer, port included, when there is no Origin" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler
      context, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com:8080", "Referer" => "http://example.com:8080/form?x=1"}, handler)

      handler.call(context)

      context.response.status_code.should eq 200
      verify_calls.call
    end

    it "trusts an origin a CORS handler allowed earlier in the chain" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"] of (String | Regex), methods: %w(POST), headers: %w(Content-Type))
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      cors.next = handler
      handler.next = next_handler
      context, _ = signed_post("/submit", HTTP::Headers{"Host" => "api.example", "Origin" => "https://app.example"}, handler)

      cors.call(context)

      context.response.status_code.should eq 200
      verify_calls.call

      refused, _ = signed_post("/submit", HTTP::Headers{"Host" => "api.example", "Origin" => "https://evil.example"}, handler)
      cors.call(refused)
      refused.response.status_code.should eq 403
    end

    it "does not trust a CORS wildcard, nor the X-Origin header" do
      wildcard = Azu::Handler::CORS.new(origins: ["*"] of (String | Regex), methods: %w(POST), headers: %w(Content-Type))
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(0)
      wildcard.next = handler
      handler.next = next_handler

      context, _ = signed_post("/submit", HTTP::Headers{"Host" => "api.example", "Origin" => "https://evil.example"}, handler)
      wildcard.call(context)
      context.response.status_code.should eq 403
      context.request.cors_allowed?.should be_false

      listed = Azu::Handler::CORS.new(origins: ["https://evil.example"] of (String | Regex), methods: %w(POST), headers: %w(Content-Type))
      listed.next = handler
      x_origin, _ = signed_post("/submit", HTTP::Headers{"Host" => "api.example", "X-Origin" => "https://evil.example", "Referer" => "https://evil.example/"}, handler)
      listed.call(x_origin)
      x_origin.response.status_code.should eq 403
      verify_calls.call
    end

    it "is off with check_origin: false" do
      handler = Azu::Handler::CSRF.new(check_origin: false)
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler
      context, _ = signed_post("/submit", HTTP::Headers{"Host" => "example.com", "Origin" => "https://evil.example"}, handler)

      handler.call(context)

      context.response.status_code.should eq 200
      verify_calls.call
    end
  end

  describe "where the token is read from" do
    it "ignores a token in the query string" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(0)
      handler.next = next_handler
      get_context, _ = create_context("GET", "/")
      token = handler.token(get_context)
      context, _ = create_context("POST", "/submit?_csrf=#{URI.encode_www_form(token)}", HTTP::Headers{"Cookie" => "csrf_token=#{token}"})

      handler.call(context)

      context.response.status_code.should eq 403
      verify_calls.call
    end
  end

  describe "the secret" do
    it "warns, when a handler is built or its key is set, that the secret is shorter than 32 bytes" do
      backend = ::Log::MemoryBackend.new
      log = ::Log.new("csrf_secret_spec", backend, :warn)
      Azu::Handler::CSRF.new(secret_key: "short", log: log)
      long = Azu::Handler::CSRF.new(secret_key: "x" * 32, log: log)
      long.secret_key = "short too"

      backend.entries.map(&.message).select(&.includes?("32 bytes")).size.should eq 2
    end
  end

  describe "secure cookie configuration" do
    it "sets the Secure flag when this server terminates TLS itself" do
      Azu::Handler::CSRF.secure_cookies = true
      config = Azu.current_config
      cert, key = config.ssl_cert, config.ssl_key
      begin
        config.ssl_cert = "/etc/azu/cert.pem"
        config.ssl_key = "/etc/azu/key.pem"
        context, _ = create_context("GET", "/")

        Azu::Handler::CSRF.token(context)

        context.response.cookies.first.secure.should be_true
      ensure
        config.ssl_cert = cert
        config.ssl_key = key
      end
    end

    it "sets secure flag for HTTPS requests" do
      Azu::Handler::CSRF.secure_cookies = true

      headers = HTTP::Headers.new
      headers["X-Forwarded-Proto"] = "https"
      context, _ = create_context("GET", "/", headers)

      Azu::Handler::CSRF.token(context)

      context.response.cookies.size.should eq(1)
      cookie = context.response.cookies.first
      cookie.secure.should be_true
    end

    it "does not set secure flag for HTTP requests" do
      Azu::Handler::CSRF.secure_cookies = true

      context, _ = create_context("GET", "/")

      Azu::Handler::CSRF.token(context)

      context.response.cookies.size.should eq(1)
      cookie = context.response.cookies.first
      cookie.secure.should be_false
    end
  end
end
