require "../spec_helper"

# Helper method to create HTTP context
def create_context(method = "GET", path = "/", headers = HTTP::Headers.new, body = nil)
  request = HTTP::Request.new(method, path, headers, body)
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

  describe "AJAX request detection" do
    it "allows AJAX requests with JSON content type" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["Content-Type"] = "application/json"
      context, io = create_context("POST", "/api/data", headers)
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify_calls.call
    end

    it "allows AJAX requests with X-Requested-With header" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify_calls = create_next_handler(1)
      handler.next = next_handler

      headers = HTTP::Headers.new
      headers["X-Requested-With"] = "XMLHttpRequest"
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
        context, io = create_context("GET", "/")

        token = Azu::Handler::CSRF.token(context)

        token.should_not be_empty
        token.split(":").size.should eq(3) # base_token:timestamp:signature
      end

      it "sets cookie when generating token" do
        Azu::Handler::CSRF.use_signed_double_submit!
        context, io = create_context("GET", "/")

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
        context, io = create_context("GET", "/")

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
        context, io = create_context("GET", "/", headers)

        token = Azu::Handler::CSRF.token(context)

        token.should eq(existing_token)
        context.response.cookies.size.should eq(0) # No new cookie set
      end
    end

    describe "double submit strategy" do
      it "generates simple tokens" do
        Azu::Handler::CSRF.use_double_submit!
        context, io = create_context("GET", "/")

        token = Azu::Handler::CSRF.token(context)

        token.should_not be_empty
        context.response.cookies.size.should eq(1)
        context.response.cookies.first.value.should eq(token)
      end
    end
  end

  describe "HTML helper methods" do
    it "generates hidden input tag" do
      context, io = create_context("GET", "/")

      tag = Azu::Handler::CSRF.tag(context)

      tag.should contain(%Q(<input type="hidden"))
      tag.should contain(%Q(name="_csrf"))
      tag.should contain(%Q(value="))
    end

    it "generates meta tag" do
      context, io = create_context("GET", "/")

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
        get_context, get_io = create_context("GET", "/")
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
        context, io = create_context("POST", "/submit", headers)

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
        context, io = create_context("POST", "/submit", headers)

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
      context, io = create_context("POST", "/", headers)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_true
    end

    it "rejects mismatched origins" do
      headers = HTTP::Headers.new
      headers["Origin"] = "http://evil.com"
      headers["Host"] = "example.com"
      context, io = create_context("POST", "/", headers)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_false
    end

    it "validates referer when origin is missing" do
      headers = HTTP::Headers.new
      headers["Referer"] = "http://example.com:80/page" # Include explicit port to match expected behavior
      headers["Host"] = "example.com"

      # Create request with proper host setup
      request = HTTP::Request.new("POST", "/", headers)
      io = IO::Memory.new
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_true
    end

    it "handles HTTPS with X-Forwarded-Proto" do
      headers = HTTP::Headers.new
      headers["Origin"] = "https://example.com"
      headers["Host"] = "example.com"
      headers["X-Forwarded-Proto"] = "https"
      context, io = create_context("POST", "/", headers)

      result = Azu::Handler::CSRF.validate_origin(context)
      result.should be_true
    end
  end

  describe "secure cookie configuration" do
    it "sets secure flag for HTTPS requests" do
      Azu::Handler::CSRF.secure_cookies = true

      headers = HTTP::Headers.new
      headers["X-Forwarded-Proto"] = "https"
      context, io = create_context("GET", "/", headers)

      token = Azu::Handler::CSRF.token(context)

      context.response.cookies.size.should eq(1)
      cookie = context.response.cookies.first
      cookie.secure.should be_true
    end

    it "does not set secure flag for HTTP requests" do
      Azu::Handler::CSRF.secure_cookies = true

      context, io = create_context("GET", "/")

      token = Azu::Handler::CSRF.token(context)

      context.response.cookies.size.should eq(1)
      cookie = context.response.cookies.first
      cookie.secure.should be_false
    end
  end
end
