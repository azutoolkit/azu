require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

module EndpointCsrfSpec
  struct Text
    include Azu::Response

    def initialize(@text : String)
    end

    def render
      @text
    end
  end

  # Prints all three of its CSRF helpers in one response.
  struct TokensEndpoint
    include Azu::Endpoint(Azu::Request, Text)

    def call : Text
      Text.new("#{csrf_token}|#{csrf_tag}|#{csrf_metatag}")
    end
  end

  # A synchronizer token store that is not the handler's cookie.
  class MemoryStore < Azu::Handler::CSRF::TokenStore
    getter token : String?

    def read(context : HTTP::Server::Context) : String?
      @token
    end

    def write(context : HTTP::Server::Context, token : String) : Nil
      @token = token
    end
  end
end

describe Azu::Handler::CSRF do
  describe "initialization" do
    it "initializes with default values" do
      handler = Azu::Handler::CSRF.new
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with custom secret key" do
      handler = Azu::Handler::CSRF.new(secret_key: "my-secret-key-32-chars-long!!")
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with custom parameter name" do
      handler = Azu::Handler::CSRF.new(param_name: "_custom_csrf")
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with custom header name" do
      handler = Azu::Handler::CSRF.new(header_name: "X-Custom-CSRF")
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with custom cookie name" do
      handler = Azu::Handler::CSRF.new(cookie_name: "custom_csrf_cookie")
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with SynchronizerToken strategy" do
      handler = Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken)
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with SignedDoubleSubmit strategy" do
      handler = Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::SignedDoubleSubmit)
      handler.should be_a(Azu::Handler::CSRF)
    end

    it "initializes with DoubleSubmit strategy" do
      handler = Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::DoubleSubmit)
      handler.should be_a(Azu::Handler::CSRF)
    end
  end

  describe "safe methods" do
    it "allows GET requests without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/test")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "allows HEAD requests without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("HEAD", "/test")
      handler.call(context)

      verify.call
    end

    it "allows OPTIONS requests without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("OPTIONS", "/test")
      handler.call(context)

      verify.call
    end
  end

  describe "unsafe methods" do
    it "rejects POST request without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, verify = create_next_handler(0)
      handler.next = next_handler

      context, io = create_context("POST", "/test")
      handler.call(context)

      context.response.status_code.should eq(403)
    end

    it "rejects PUT request without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, _ = create_next_handler(0)
      handler.next = next_handler

      context, _ = create_context("PUT", "/test")
      handler.call(context)

      context.response.status_code.should eq(403)
    end

    it "rejects PATCH request without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, _ = create_next_handler(0)
      handler.next = next_handler

      context, _ = create_context("PATCH", "/test")
      handler.call(context)

      context.response.status_code.should eq(403)
    end

    it "rejects DELETE request without token" do
      handler = Azu::Handler::CSRF.new
      next_handler, _ = create_next_handler(0)
      handler.next = next_handler

      context, _ = create_context("DELETE", "/test")
      handler.call(context)

      context.response.status_code.should eq(403)
    end
  end

  describe "excluded paths" do
    it "skips CSRF check for excluded paths" do
      handler = Azu::Handler::CSRF.new(skip_routes: ["/api/webhook"])
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, _ = create_context("POST", "/api/webhook")
      handler.call(context)

      verify.call
    end

    it "does not skip CSRF for non-excluded paths" do
      handler = Azu::Handler::CSRF.new(skip_routes: ["/api/webhook"])
      next_handler, _ = create_next_handler(0)
      handler.next = next_handler

      context, _ = create_context("POST", "/api/users")
      handler.call(context)

      context.response.status_code.should eq(403)
    end
  end

  describe "error responses" do
    it "returns 403 Forbidden status" do
      handler = Azu::Handler::CSRF.new
      next_handler, _ = create_next_handler(0)
      handler.next = next_handler

      context, _ = create_context("POST", "/test")
      handler.call(context)

      context.response.status_code.should eq(403)
    end
  end

  describe "tags for a token already issued" do
    it "escapes the token" do
      handler = Azu::Handler::CSRF.new(secret_key: "my-secret-key-32-chars-long!!")

      handler.tag(%(a"b<c)).should eq %(<input type="hidden" name="_csrf" value="a&quot;b&lt;c" />)
      handler.metatag(%(a"b<c)).should eq %(<meta name="_csrf" content="a&quot;b&lt;c" />)
    end
  end

  describe "one response" do
    Azu::Handler::CSRF::Strategy.each do |strategy|
      it "gives an endpoint's csrf_token, csrf_tag and csrf_metatag the token the CSRF cookie holds (#{strategy})" do
        previous = Azu::Handler::CSRF.strategy
        Azu::Handler::CSRF.strategy = strategy
        begin
          io = IO::Memory.new
          context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/form"), HTTP::Server::Response.new(io))
          EndpointCsrfSpec::TokensEndpoint.new.call(context)
          context.response.close
          token, tag, metatag = io.to_s.split("\r\n\r\n", 2).last.split('|')
          param = Azu::Handler::CSRF.param_name

          tag.should eq %(<input type="hidden" name="#{param}" value="#{token}" />)
          metatag.should eq %(<meta name="#{param}" content="#{token}" />)
          context.response.cookies[Azu::Handler::CSRF.cookie_name].value.should eq token
        ensure
          Azu::Handler::CSRF.strategy = previous
        end
      end
    end

    it "issues a handler's token once, under that handler's own cookie name" do
      handler = Azu::Handler::CSRF.new(cookie_name: "custom_csrf_cookie", secret_key: "my-secret-key-32-chars-long!!")
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/form"), HTTP::Server::Response.new(IO::Memory.new))

      first = handler.token(context)
      handler.token(context).should eq first
      context.response.cookies["custom_csrf_cookie"].value.should eq first
    end

    {
      "a deletion"     => HTTP::Cookie.new("custom_csrf_cookie", "old", max_age: 0.seconds),
      "an empty"       => HTTP::Cookie.new("custom_csrf_cookie", ""),
      "an expired"     => HTTP::Cookie.new("custom_csrf_cookie", "stale", expires: Time.utc - 1.day),
      "another path's" => HTTP::Cookie.new("custom_csrf_cookie", "admin", path: "/admin"),
    }.each do |kind, cookie|
      it "issues a fresh token over #{kind} cookie already on the response" do
        handler = Azu::Handler::CSRF.new(cookie_name: "custom_csrf_cookie", secret_key: "my-secret-key-32-chars-long!!")
        context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/form"), HTTP::Server::Response.new(IO::Memory.new))
        context.response.cookies << cookie

        token = handler.token(context)
        token.should_not be_empty
        token.should_not eq cookie.value
        context.response.cookies["custom_csrf_cookie"].value.should eq token
      end
    end

    it "does not print the request's synchronizer token while the response deletes its cookie" do
      handler = Azu::Handler::CSRF.new(strategy: :synchronizer_token, cookie_name: "custom_csrf_cookie")
      request = HTTP::Request.new("GET", "/logout", HTTP::Headers{"Cookie" => "custom_csrf_cookie=from-request"})
      context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
      context.response.cookies << HTTP::Cookie.new("custom_csrf_cookie", "", max_age: 0.seconds)

      token = handler.token(context)
      token.should_not eq "from-request"
      context.response.cookies["custom_csrf_cookie"].value.should eq token
    end

    it "keeps a synchronizer token in its store whatever cookie of that name the response holds" do
      store = EndpointCsrfSpec::MemoryStore.new
      handler = Azu::Handler::CSRF.new(strategy: :synchronizer_token, cookie_name: "custom_csrf_cookie", token_store: store)
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/form"), HTTP::Server::Response.new(IO::Memory.new))
      context.response.cookies << HTTP::Cookie.new("custom_csrf_cookie", "another-handlers-token")

      token = handler.token(context)
      token.should_not eq "another-handlers-token"
      store.token.should eq token
    end
  end
end
