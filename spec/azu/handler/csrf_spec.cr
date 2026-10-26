require "../../spec_helper"
require "../../support/integration_helpers"
require "../../../src/azu/testing/testing"

include IntegrationHelpers

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

  describe "token cookie" do
    # Without a Path a browser keeps the cookie for the directory of the page that set it (RFC 6265
    # default-path): a token issued on GET /auth/login would not be sent with POST /session.
    {% for strategy in %w(SignedDoubleSubmit DoubleSubmit SynchronizerToken) %}
      it "is set for every path with {{strategy.id}}" do
        handler = Azu::Handler::CSRF.new(
          strategy: Azu::Handler::CSRF::Strategy::{{strategy.id}},
          secret_key: "test-secret",
        )
        context, io = create_context("GET", "/auth/login")

        handler.token(context)

        context.response.cookies["csrf_token"].path.should eq("/")
        context.response.close
        io.rewind
        set_cookie = io.gets_to_end.lines.find!(&.starts_with?("Set-Cookie: csrf_token="))
        set_cookie.should match(/;\s*path=\/(;|$)/i)
      end
    {% end %}

    # A browser that still holds a cookie of an earlier version (Path=/auth) sends it before the
    # Path=/ one (longer paths first); the handler compares against the last of the name.
    it "validates against the Path=/ cookie when an older directory cookie comes first" do
      handler = Azu::Handler::CSRF.new(secret_key: "test-secret")
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      stale = handler.token(create_context("GET", "/auth/login")[0])
      fresh = handler.token(create_context("GET", "/auth/login")[0])

      headers = HTTP::Headers{
        "Cookie"       => "csrf_token=#{stale}; csrf_token=#{fresh}",
        "X-CSRF-TOKEN" => fresh,
      }
      context, _ = create_context("POST", "/auth/login", headers)
      handler.call(context)

      context.response.status_code.should eq(200)
      verify.call
    end
  end
end

module CSRFFormSpec
  struct FormPage
    include Azu::Response
    include Azu::Templates::Renderable

    def render
      view "csrf_form.jinja"
    end
  end

  struct ShowForm
    include Azu::Endpoint(Azu::Request, FormPage)

    def call : FormPage
      FormPage.new
    end
  end

  struct SubmitForm
    include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

    def call : Azu::Response::Empty
      Azu::Response::Empty.new
    end
  end

  def self.app : Azu::App
    app = Azu::App.new
    app.config.templates.path = "spec/test_templates"
    app.routes do
      get "/csrf-form", ShowForm
      post "/csrf-form", SubmitForm
    end
    app
  end
end

describe "CSRF tokens in rendered pages" do
  {% for strategy in %w(SignedDoubleSubmit DoubleSubmit SynchronizerToken) %}
    it "issues one token per response with {{strategy.id}}" do
      handler = Azu::Handler::CSRF.new(strategy: Azu::Handler::CSRF::Strategy::{{strategy.id}}, secret_key: "test-secret")
      context, _ = create_context("GET", "/posts/new")

      token = handler.token(context)

      handler.token(context).should eq(token)
      handler.tag(context).should contain(token)
      handler.metatag(context).should contain(token)
      context.response.cookies["csrf_token"].value.should eq(token)
    end
  {% end %}

  it "accepts the form a response rendered" do
    Azu::Handler::CSRF.configure { |csrf| csrf.secret_key = "test-secret" }
    client = Azu::Testing::Client.new(CSRFFormSpec.app, [Azu::Handler::RequestId.new, Azu::Handler::CSRF.default] of HTTP::Handler)

    page = client.get("/csrf-form")
    token = page.body.match!(/name="_csrf" value="([^"]+)"/)[1]

    client.post("/csrf-form", form: {"_csrf" => token}).status_code.should eq(200)
  ensure
    Azu::Handler::CSRF.reset_default!
  end
end
