require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

private def cors_get(cors : Azu::Handler::CORS, origin : String?, method = "GET") : HTTP::Server::Context
  cors.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
  headers = HTTP::Headers.new
  headers["Origin"] = origin if origin
  context, _ = create_context(method, "/test", headers)
  cors.call(context)
  context
end

private def vary_of(context) : Array(String)
  (context.response.headers.get?("Vary") || [] of String).flat_map(&.split(',')).map(&.strip)
end

describe "Azu::Handler::CORS origins and credentials" do
  describe "a wildcard with credentials" do
    it "is refused at construction with a message naming both options" do
      error = expect_raises(ArgumentError, /"\*".*credentials: true/) do
        Azu::Handler::CORS.new(origins: ["*"], credentials: true)
      end
      error.message.to_s.should contain("list the allowed origins")
    end

    it "is refused when the wildcard is one of several origins" do
      expect_raises(ArgumentError) { Azu::Handler::CORS.new(origins: ["https://a.example", "*"], credentials: true) }
    end

    it "is refused through the setters too, and the handler keeps its old settings" do
      cors = Azu::Handler::CORS.new(origins: ["*"])
      expect_raises(ArgumentError) { cors.credentials = true }
      cors.credentials.should be_false

      listed = Azu::Handler::CORS.new(origins: ["https://a.example"], credentials: true)
      expect_raises(ArgumentError) { listed.origins = ["*"] of (String | Regex) }
      listed.origins.should eq ["https://a.example"]
      cors_get(listed, "https://evil.example").response.status_code.should eq 403
    end

    it "is accepted without credentials, and credentials are accepted with listed origins and regexes" do
      Azu::Handler::CORS.new(origins: ["*"], credentials: false)
      Azu::Handler::CORS.new(origins: ["https://a.example", /\Ahttps:\/\/[a-z]+\.b\.example\z/], credentials: true)
    end
  end

  describe "a wildcard without credentials" do
    it "sends a literal * and varies by Origin" do
      context = cors_get(Azu::Handler::CORS.new(origins: ["*"]), "https://a.example")
      context.response.headers["Access-Control-Allow-Origin"].should eq "*"
      context.response.headers.has_key?("Access-Control-Allow-Credentials").should be_false
      vary_of(context).should contain("Origin")
    end

    it "sends * for a wildcard listed beside other origins" do
      context = cors_get(Azu::Handler::CORS.new(origins: ["https://a.example", "*"]), "https://b.example")
      context.response.headers["Access-Control-Allow-Origin"].should eq "*"
    end

    it "varies by Origin on a request without one" do
      context = cors_get(Azu::Handler::CORS.new(origins: ["*"]), nil)
      vary_of(context).should contain("Origin")
      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_false
    end

    it "does not match Origin: null" do
      context = cors_get(Azu::Handler::CORS.new(origins: ["*"]), "null")
      context.response.status_code.should eq 403
      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_false
    end
  end

  describe "a listed origin" do
    cors = ->(credentials : Bool) { Azu::Handler::CORS.new(origins: ["https://app.example"], credentials: credentials) }

    it "is reflected with Vary: Origin, and with credentials when asked" do
      context = cors_get(cors.call(true), "https://app.example")
      context.response.headers["Access-Control-Allow-Origin"].should eq "https://app.example"
      context.response.headers["Access-Control-Allow-Credentials"].should eq "true"
      vary_of(context).should contain("Origin")
    end

    {
      "a subdomain"            => "https://sub.app.example",
      "a parent domain"        => "https://example",
      "a lookalike suffix"     => "https://app.example.evil.test",
      "a lookalike prefix"     => "https://evilapp.example",
      "another port"           => "https://app.example:8443",
      "another scheme"         => "http://app.example",
      "a trailing slash"       => "https://app.example/",
      "a path"                 => "https://app.example/x",
      "another case"           => "https://APP.example",
      "userinfo"               => "https://app.example@evil.test",
      "userinfo the other way" => "https://evil.test@app.example",
      "whitespace"             => " https://app.example",
      "a trailing space"       => "https://app.example ",
      "an empty origin"        => "",
      "a comma-joined pair"    => "https://app.example,https://evil.test",
      "null"                   => "null",
      "NULL"                   => "NULL",
    }.each do |name, origin|
      it "refuses #{name} without any CORS header" do
        context = cors_get(cors.call(true), origin)
        context.response.status_code.should eq 403
        context.response.headers.map { |name, _| name }.select(&.downcase.starts_with?("access-control-")).should be_empty
        vary_of(context).should contain("Origin")
      end
    end

    it "refuses two Origin headers even when the first is listed, and when both are" do
      handler = cors.call(false)
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
      [["https://app.example", "https://evil.test"], ["https://evil.test", "https://app.example"], ["https://app.example", "https://app.example"]].each do |values|
        headers = HTTP::Headers.new
        values.each { |value| headers.add("Origin", value) }
        context, _ = create_context("GET", "/test", headers)
        handler.call(context)
        context.response.status_code.should eq 403
        context.response.headers.has_key?("Access-Control-Allow-Origin").should be_false
      end
    end

    it "refuses two X-Origin headers" do
      headers = HTTP::Headers.new
      headers.add("X-Origin", "https://app.example")
      headers.add("X-Origin", "https://evil.test")
      handler = cors.call(false)
      handler.next = ->(context : HTTP::Server::Context) { }
      context, _ = create_context("GET", "/test", headers)
      handler.call(context)
      context.response.status_code.should eq 403
    end

    it "lets Origin win over X-Origin" do
      headers = HTTP::Headers{"Origin" => "https://evil.test", "X-Origin" => "https://app.example"}
      handler = cors.call(false)
      handler.next = ->(context : HTTP::Server::Context) { }
      context, _ = create_context("GET", "/test", headers)
      handler.call(context)
      context.response.status_code.should eq 403
    end
  end

  describe "Origin: null" do
    it "matches only when the string null is listed" do
      context = cors_get(Azu::Handler::CORS.new(origins: ["null"]), "null")
      context.response.status_code.should eq 200
      context.response.headers["Access-Control-Allow-Origin"].should eq "null"
    end

    it "is not matched by a regex that matches everything" do
      context = cors_get(Azu::Handler::CORS.new(origins: [/.*/]), "null")
      context.response.status_code.should eq 403
      context.response.headers.has_key?("Access-Control-Allow-Origin").should be_false
    end

    it "is a documented trap with credentials: any sandboxed frame is then allowed" do
      cors = Azu::Handler::CORS.new(origins: ["null"], credentials: true)
      context = cors_get(cors, "null")
      context.response.headers["Access-Control-Allow-Origin"].should eq "null"
      context.response.headers["Access-Control-Allow-Credentials"].should eq "true"
    end

    it "is not matched by listing other origins, credentials or not" do
      cors_get(Azu::Handler::CORS.new(origins: ["https://a.example"], credentials: true), "null").response.status_code.should eq 403
    end
  end

  describe "regex origins" do
    it "never see a malformed Origin" do
      cors = Azu::Handler::CORS.new(origins: [/https:\/\/[a-z0-9]+\.example\.com/])
      cors_get(cors, "https://evil.test/x.example.com").response.status_code.should eq 403
      cors_get(cors, "https://evil.test/https://a.example.com").response.status_code.should eq 403
      cors_get(cors, "https://evil.test,https://a.example.com").response.status_code.should eq 403
      cors_get(cors, "https://a.example.com").response.status_code.should eq 200
    end
  end

  describe "regex origins match the whole Origin" do
    it "does not let an unanchored regex allow a lookalike, with credentials echoed" do
      cors = Azu::Handler::CORS.new(origins: [/good\.com/], credentials: true)
      ["https://good.com.evil.test", "https://evilgood.com", "https://good.com", "http://good.com", "https://sub.good.com"].each do |origin|
        context = cors_get(cors, origin)
        context.response.status_code.should eq 403
        context.response.headers.has_key?("Access-Control-Allow-Credentials").should be_false
      end
    end

    it "allows what the regex describes in full, alternations and options included" do
      cors = Azu::Handler::CORS.new(origins: [/https:\/\/(?:a|b)\.test/, /HTTPS:\/\/c\.test/i, /https:\/\/d\.test|https:\/\/e\.test/])
      %w(https://a.test https://b.test https://c.test https://d.test https://e.test).each do |origin|
        cors_get(cors, origin).response.status_code.should eq 200
      end
      %w(https://a.test.evil https://xa.test https://f.test https://d.testx).each do |origin|
        cors_get(cors, origin).response.status_code.should eq 403
      end
    end

    it "still accepts a regex that anchors itself" do
      cors = Azu::Handler::CORS.new(origins: [/\Ahttps:\/\/app\.test\z/, /^https:\/\/api\.test$/])
      cors_get(cors, "https://app.test").response.status_code.should eq 200
      cors_get(cors, "https://api.test").response.status_code.should eq 200
    end
  end

  describe "preflight" do
    preflight = ->(cors : Azu::Handler::CORS, origin : String, method : String?, request_headers : String?) {
      cors.next = ->(context : HTTP::Server::Context) { }
      headers = HTTP::Headers{"Origin" => origin}
      headers["Access-Control-Request-Method"] = method if method
      headers["Access-Control-Request-Headers"] = request_headers if request_headers
      context, _ = create_context("OPTIONS", "/test", headers)
      cors.call(context)
      context
    }
    cors = -> { Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["POST", "PUT"], headers: ["Content-Type", "X-Token"], max_age: 600) }

    it "allows when every requested header is allowed, whatever the case, spacing and empty items" do
      context = preflight.call(cors.call, "https://app.example", "PUT", " content-type ,X-TOKEN,, ")
      context.response.status_code.should eq 200
      context.response.headers["Access-Control-Allow-Methods"].should eq "PUT"
      context.response.headers["Access-Control-Max-Age"].should eq "600"
    end

    it "refuses when only some of the requested headers are allowed" do
      context = preflight.call(cors.call, "https://app.example", "POST", "Content-Type, X-Evil")
      context.response.status_code.should eq 403
      context.response.headers.map { |name, _| name }.select(&.downcase.starts_with?("access-control-")).should be_empty
    end

    it "allows a preflight without Access-Control-Request-Headers and sends no Allow-Headers" do
      context = preflight.call(cors.call, "https://app.example", "DELETE", nil)
      context.response.status_code.should eq 403 # DELETE is not in this handler's methods

      context = preflight.call(cors.call, "https://app.example", "PUT", nil)
      context.response.status_code.should eq 200
      context.response.headers["Access-Control-Allow-Origin"].should eq "https://app.example"
      context.response.headers["Access-Control-Allow-Methods"].should eq "PUT"
      context.response.headers.has_key?("Access-Control-Allow-Headers").should be_false
    end

    it "still needs an allowed method and origin when no headers are requested" do
      preflight.call(cors.call, "https://app.example", "DELETE", nil).response.status_code.should eq 403
      preflight.call(cors.call, "https://evil.test", "PUT", nil).response.status_code.should eq 403
    end

    it "refuses a header list holding nothing but separators" do
      preflight.call(cors.call, "https://app.example", "POST", " , ").response.status_code.should eq 403
    end

    it "refuses a method that is not allowed, and a lower-case method" do
      preflight.call(cors.call, "https://app.example", "DELETE", "Content-Type").response.status_code.should eq 403
      preflight.call(cors.call, "https://app.example", "post", "Content-Type").response.status_code.should eq 403
    end

    it "treats an OPTIONS request without Access-Control-Request-Method as an ordinary request" do
      handler = cors.call
      reached = false
      handler.next = ->(context : HTTP::Server::Context) { reached = true }
      context, _ = create_context("OPTIONS", "/test", HTTP::Headers{"Origin" => "https://app.example"})
      handler.call(context)
      reached.should be_true
      context.response.headers["Access-Control-Allow-Origin"].should eq "https://app.example"
      context.response.headers.has_key?("Access-Control-Allow-Methods").should be_false

      other, _ = create_context("OPTIONS", "/test", HTTP::Headers{"Origin" => "https://evil.test"})
      handler.call(other)
      other.response.status_code.should eq 403
    end

    it "sends the allowed headers in their configured spelling, in the order asked, without duplicates" do
      context = preflight.call(cors.call, "https://app.example", "POST", "x-token, CONTENT-TYPE, content-type")
      context.response.headers["Access-Control-Allow-Headers"].should eq "X-Token, Content-Type"
    end

    it "drops every Access-Control header, the expose list included, from a refused preflight" do
      handler = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["POST"], headers: ["Content-Type"], credentials: true, expose_headers: ["X-Request-ID"], max_age: 600)
      context = preflight.call(handler, "https://app.example", "DELETE", "Content-Type")
      context.response.status_code.should eq 403
      context.response.headers.map { |name, _| name }.select(&.downcase.starts_with?("access-control-")).should be_empty
    end

    it "gives a non-listed origin no CORS header at all, whatever it asks for" do
      context = preflight.call(cors.call, "https://evil.test", "POST", "Content-Type")
      context.response.status_code.should eq 403
      context.response.headers.map { |name, _| name }.select(&.downcase.starts_with?("access-control-")).should be_empty
    end

    it "sends the literal * with a wildcard and no credentials" do
      wild = Azu::Handler::CORS.new(origins: ["*"], methods: ["POST"], headers: ["Content-Type"])
      context = preflight.call(wild, "https://anything.example", "POST", "Content-Type")
      context.response.headers["Access-Control-Allow-Origin"].should eq "*"
    end

    it "omits Max-Age when it is nil" do
      handler = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["POST"], headers: ["Content-Type"], max_age: nil)
      preflight.call(handler, "https://app.example", "POST", "Content-Type").response.headers.has_key?("Access-Control-Max-Age").should be_false
    end
  end

  describe "over a real server" do
    serve = ->(cors : Azu::Handler::CORS, method : String, headers : HTTP::Headers) {
      server = HTTP::Server.new([cors] of HTTP::Handler) { |context| context.response.print "OK" }
      address = server.bind_unused_port("127.0.0.1")
      spawn { server.listen }
      Fiber.yield
      begin
        HTTP::Client.new(address.address, address.port).exec(method, "/", headers)
      ensure
        server.close
      end
    }

    it "sends * and Vary: Origin for a wildcard, to every origin" do
      cors = Azu::Handler::CORS.new(origins: ["*"])
      ["https://a.example", "https://b.example"].each do |origin|
        response = serve.call(cors, "GET", HTTP::Headers{"Origin" => origin})
        response.headers["Access-Control-Allow-Origin"].should eq "*"
        response.headers["Vary"].should eq "Origin"
      end
    end

    it "answers a credentialed listed origin with that origin only, and a lookalike with nothing" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], credentials: true)
      ok = serve.call(cors, "GET", HTTP::Headers{"Origin" => "https://app.example"})
      ok.headers["Access-Control-Allow-Origin"].should eq "https://app.example"
      ok.headers["Access-Control-Allow-Credentials"].should eq "true"
      ok.headers["Vary"].should eq "Origin"

      ["null", "https://app.example.evil.test", "https://app.example:81"].each do |origin|
        refused = serve.call(cors, "GET", HTTP::Headers{"Origin" => origin})
        refused.status_code.should eq 403
        refused.headers["Access-Control-Allow-Origin"]?.should be_nil
        refused.headers["Access-Control-Allow-Credentials"]?.should be_nil
      end
    end

    it "refuses two Origin headers on the wire" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"])
      headers = HTTP::Headers.new
      headers.add("Origin", "https://app.example")
      headers.add("Origin", "https://evil.test")
      response = serve.call(cors, "GET", headers)
      response.status_code.should eq 403
      response.headers["Access-Control-Allow-Origin"]?.should be_nil
    end

    it "answers a bare cross-origin DELETE preflight (no request headers) with the allowed method only" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["DELETE"], headers: ["Content-Type"])
      response = serve.call(cors, "OPTIONS", HTTP::Headers{"Origin" => "https://app.example", "Access-Control-Request-Method" => "DELETE"})
      response.status_code.should eq 200
      response.headers["Access-Control-Allow-Methods"].should eq "DELETE"
      response.headers["Access-Control-Allow-Headers"]?.should be_nil
    end

    it "puts Allow-Origin, Allow-Credentials, Expose-Headers and Vary on an accepted preflight on the wire" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["PUT"], headers: ["Content-Type"], credentials: true, expose_headers: ["X-Request-ID"])
      response = serve.call(cors, "OPTIONS", HTTP::Headers{
        "Origin"                         => "https://app.example",
        "Access-Control-Request-Method"  => "PUT",
        "Access-Control-Request-Headers" => "content-type",
      })
      response.status_code.should eq 200
      response.headers["Access-Control-Allow-Origin"].should eq "https://app.example"
      response.headers["Access-Control-Allow-Credentials"].should eq "true"
      response.headers["Access-Control-Expose-Headers"].should eq "X-Request-ID"
      response.headers["Access-Control-Allow-Headers"].should eq "Content-Type"
      response.headers["Vary"].should eq "Origin"
    end

    it "refuses a preflight asking for one allowed and one forbidden header on the wire" do
      cors = Azu::Handler::CORS.new(origins: ["https://app.example"], methods: ["POST"], headers: ["Content-Type"])
      response = serve.call(cors, "OPTIONS", HTTP::Headers{
        "Origin"                         => "https://app.example",
        "Access-Control-Request-Method"  => "POST",
        "Access-Control-Request-Headers" => "Content-Type, X-Evil",
      })
      response.status_code.should eq 403
      response.headers["Access-Control-Allow-Headers"]?.should be_nil
    end
  end
end
