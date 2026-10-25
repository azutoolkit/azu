require "../spec_helper"
require "http/client"

private def request(accept : String? = nil, query : String = "") : HTTP::Request
  headers = HTTP::Headers.new
  headers["Accept"] = accept if accept
  HTTP::Request.new("GET", "/page#{query}", headers)
end

private ALL = [Azu::Negotiation::Format::Html, Azu::Negotiation::Format::Json, Azu::Negotiation::Format::Xml, Azu::Negotiation::Format::Text]

private def pick(accept : String?, formats = ALL, query : String = "") : String?
  Azu::Negotiation.negotiate(formats, request(accept, query)).try(&.media_type)
end

struct NegSpecPage
  include Azu::Response::Negotiable

  def initialize(@name : String)
  end

  def render_html : String
    "<h1>#{HTML.escape(@name)}</h1>"
  end

  def render_json : String
    {name: @name}.to_json
  end

  def render_xml : String
    "<name>#{HTML.escape(@name)}</name>"
  end
end

private struct JsonFirst
  include Azu::Response::Negotiable
  prefer :json, :html

  def render_html : String
    "<p>html</p>"
  end

  def render_json : String
    %({"ok":true})
  end
end

private struct ShowEndpoint
  include Azu::Endpoint(Azu::Request, NegSpecPage)

  get "/neg-page"

  def call : NegSpecPage
    NegSpecPage.new("<Ada>")
  end
end

private struct ApiEndpoint
  include Azu::Endpoint(Azu::Request, JsonFirst)

  get "/neg-api"

  def call : JsonFirst
    JsonFirst.new
  end
end

private CREATED = [] of Int32

struct NegSpecOther
  include Azu::Response::Negotiable

  def render_json : String
    "{}"
  end

  def render_text : String
    "x"
  end
end

# A union of negotiable responses is checked against the formats all of them render.
private struct EitherEndpoint
  include Azu::Endpoint(Azu::Request, NegSpecPage | NegSpecOther)

  post "/neg-either"

  def call : NegSpecPage | NegSpecOther
    CREATED << 2
    NegSpecOther.new
  end
end

private struct CreateEndpoint
  include Azu::Endpoint(Azu::Request, JsonFirst)

  post "/neg-create"

  def call : JsonFirst
    CREATED << 1
    JsonFirst.new
  end
end

private def get(app : Azu::App, path : String, accept : String? = nil, method : String = "GET") : HTTP::Client::Response
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  headers = HTTP::Headers.new
  headers["Accept"] = accept if accept
  begin
    HTTP::Client.exec(method, "http://#{address.address}:#{address.port}#{path}", headers)
  ensure
    server.close
  end
end

private def negotiating_app : Azu::App
  app = Azu::App.new
  app.routes do
    endpoint ShowEndpoint
    endpoint ApiEndpoint
    endpoint CreateEndpoint
    endpoint EitherEndpoint
  end
  app
end

describe Azu::Negotiation do
  describe ".ranges" do
    it "reads q values and keeps header order, skipping what is not a media range" do
      ranges = Azu::Negotiation.ranges("text/html, bogus, application/json;q=0.5, */*;q=0")

      ranges.map { |range| {range.type, range.subtype, range.quality, range.position} }.should eq [
        {"text", "html", 1.0, 0},
        {"application", "json", 0.5, 1},
        {"*", "*", 0.0, 2},
      ]
    end

    it "yields nothing for a missing or unusable header" do
      Azu::Negotiation.ranges(nil).should be_empty
      Azu::Negotiation.ranges("???").should be_empty
    end
  end

  describe ".negotiate" do
    it "answers the first format without Accept, with */*, or with a header that is not valid" do
      pick(nil).should eq "text/html"
      pick("*/*").should eq "text/html"
      pick("not a header").should eq "text/html"
      pick("", [Azu::Negotiation::Format::Json, Azu::Negotiation::Format::Html]).should eq "application/json"
    end

    it "prefers the higher q" do
      pick("application/json;q=0.5, text/html;q=0.9").should eq "text/html"
      pick("text/html;q=0.1, application/json").should eq "application/json"
    end

    it "lets a specific range beat a wildcard at the same q" do
      pick("*/*, application/xml").should eq "application/xml"
      pick("text/*, application/json").should eq "application/json"
    end

    it "takes the q of the most specific range for a format" do
      pick("text/*;q=0.1, text/html;q=0.8, application/json;q=0.5").should eq "text/html"
      pick("text/*;q=0.9, text/html;q=0.1, application/json;q=0.5").should eq "text/plain"
    end

    it "refuses a format with q=0" do
      pick("*/*;q=0.1, text/html;q=0", [Azu::Negotiation::Format::Html, Azu::Negotiation::Format::Json]).should eq "application/json"
      pick("text/html;q=0", [Azu::Negotiation::Format::Html]).should be_nil
    end

    it "breaks a tie by the client's order, then by the server's" do
      pick("application/json, text/html").should eq "application/json"
      pick("text/*").should eq "text/html"
    end

    it "leaves a q that is not a finite number to the default instead of failing" do
      Azu::Negotiation.ranges("text/html;q=nan, application/json;q=inf, application/xml;q=abc").map(&.quality).should eq [1.0, 1.0, 1.0]
      pick("text/html;q=nan, application/json;q=0.5").should eq "text/html"
    end

    it "answers nothing when no range matches" do
      pick("image/png").should be_nil
    end

    it "lets ?format= replace the header" do
      pick("application/json", query: "?format=html").should eq "text/html"
      pick(nil, query: "?format=txt").should eq "text/plain"
      pick("application/json", query: "?format=yaml").should eq "application/json"
      pick(nil, [Azu::Negotiation::Format::Html], query: "?format=json").should be_nil
    end
  end
end

describe "the format parameter" do
  it "can be renamed or turned off, and ignores values that are not format names" do
    config = Azu::CONFIG
    original = config.format_parameter
    begin
      config.format_parameter = "as"
      pick("application/json", query: "?format=html").should eq "application/json"
      pick("application/json", query: "?as=html").should eq "text/html"

      config.format_parameter = nil
      pick("application/json", query: "?format=html").should eq "application/json"
    ensure
      config.format_parameter = original
    end
  end
end

private class BaseDocument
  include Azu::Response::Negotiable

  def render_json : String
    "{}"
  end
end

private class FullDocument < BaseDocument
  def render_html : String
    "<p>"
  end
end

private module XmlRendering
  def render_xml : String
    "<x/>"
  end
end

private struct MixedDocument
  include Azu::Response::Negotiable
  include XmlRendering
end

describe Azu::Response::Negotiable do
  it "finds render methods inherited from a parent class or an included module" do
    FullDocument.formats.should eq [Azu::Negotiation::Format::Html, Azu::Negotiation::Format::Json]
    MixedDocument.formats.should eq [Azu::Negotiation::Format::Xml]
    FullDocument.new.render_as(Azu::Negotiation::Format::Json).should eq "{}"
    MixedDocument.new.render_as(Azu::Negotiation::Format::Xml).should eq "<x/>"
  end

  it "lists the formats the type defines, preferred ones first" do
    NegSpecPage.formats.should eq [Azu::Negotiation::Format::Html, Azu::Negotiation::Format::Json, Azu::Negotiation::Format::Xml]
    JsonFirst.formats.should eq [Azu::Negotiation::Format::Json, Azu::Negotiation::Format::Html]
  end

  it "renders in the first format when asked without a request, as any Response does" do
    NegSpecPage.new("x").render.should eq "<h1>x</h1>"
  end

  describe "over the wire" do
    it "answers each Accept header with the best representation and says the answer varies" do
      app = negotiating_app

      html = get(app, "/neg-page", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
      html.body.should eq "<h1>&lt;Ada&gt;</h1>"
      html.headers["Content-Type"].should eq "text/html; charset=utf-8"
      html.headers["Vary"].should eq "Accept"

      json = get(app, "/neg-page", "application/json;q=0.5, text/html;q=0.1")
      json.body.should eq %({"name":"<Ada>"})
      json.headers["Content-Type"].should eq "application/json"

      get(app, "/neg-page", "application/xml").body.should eq "<name>&lt;Ada&gt;</name>"
      get(app, "/neg-page", "*/*").headers["Content-Type"].should eq "text/html; charset=utf-8"
      get(app, "/neg-page").headers["Content-Type"].should eq "text/html; charset=utf-8"
      get(app, "/neg-page", "garbage;;;").status_code.should eq 200
    end

    it "uses the preferred format for */*" do
      get(negotiating_app, "/neg-api", "*/*").headers["Content-Type"].should eq "application/json"
    end

    it "honours ?format=" do
      get(negotiating_app, "/neg-page?format=json", "text/html").body.should eq %({"name":"<Ada>"})
    end

    it "labels the 406 application/problem+json for a client that names it" do
      get(negotiating_app, "/neg-page", "image/png, application/problem+json").headers["Content-Type"].should eq "application/problem+json"
    end

    it "answers 406 as a problem document listing what it can render" do
      response = get(negotiating_app, "/neg-page", "image/png")

      response.status_code.should eq 406
      response.headers["Content-Type"].should eq "application/json"
      response.headers["Vary"].should eq "Accept"
      body = JSON.parse(response.body)
      body["status"].as_i.should eq 406
      body["title"].as_s.should eq "Not Acceptable"
      body["supported"].as_a.map(&.as_s).should eq ["text/html", "application/json", "application/xml"]
    end

    it "answers 406 before the endpoint runs" do
      CREATED.clear

      get(negotiating_app, "/neg-create", "image/png", "POST").status_code.should eq 406
      CREATED.should be_empty
      get(negotiating_app, "/neg-create", "application/json", "POST").status_code.should eq 200
      CREATED.should eq [1]
    end

    it "refuses a union of negotiable responses with what all members can render, before the endpoint runs" do
      CREATED.clear

      get(negotiating_app, "/neg-either", "text/html", "POST").status_code.should eq 406
      CREATED.should be_empty
      get(negotiating_app, "/neg-either", "application/json", "POST").status_code.should eq 200
      CREATED.should eq [2]
    end

    it "answers 406 as plain JSON in the legacy error format" do
      app = negotiating_app
      app.config.error_format = Azu::ErrorFormat::Legacy

      get(app, "/neg-page", "image/png").headers["Content-Type"].should eq "application/json"
    end
  end
end

describe "OpenAPI" do
  it "lists every media type a negotiated response renders" do
    app = negotiating_app
    document = JSON.parse(Azu::OpenAPI.document(app, Azu::OpenAPI::Info.new("t", "1")).to_json)

    content = document["paths"]["/neg-page"]["get"]["responses"]["200"]["content"].as_h
    content.keys.sort!.should eq ["application/json", "application/xml", "text/html"]
  end
end
