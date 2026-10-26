require "../spec_helper"
require "../../src/azu/testing/testing"

private struct Hello
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

private struct Noop
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context
  end
end

# Declared with the macro DSL, so App.default serves it, and registered by hand on other apps.
private struct Greeter
  include Azu::Endpoint(Azu::Request, Hello)

  post "/p2-greet"
  get "/p2-greet/:name" # last: links resolve to the last route registered

  def call : Hello
    Hello.new("#{method.to_s.upcase} #{Greeter.path(name: "me")}")
  end
end

private def get(app : Azu::App, path : String, method : String = "GET") : Azu::Testing::Response
  Azu::Testing::Client.new(app, [] of HTTP::Handler).request(method, path)
end

private class Base
  include Azu::Endpoint(Azu::Request, Hello)

  def call : Hello
    Hello.new("base")
  end
end

private class One < Base
  get "/p2-one"
end

private class Two < Base
  get "/p2-two"
  post "/p2-two"
end

describe "endpoint registration" do
  it "records the routes the macros declared on the type" do
    Greeter.routes.should eq [{"post", "/p2-greet"}, {"get", "/p2-greet/:name"}]
  end

  it "serves one endpoint type from two apps below different prefixes, each linking to itself" do
    api = Azu::App.new
    api.routes { scope("/api") { endpoint Greeter } }
    admin = Azu::App.new
    admin.routes { scope("/admin") { endpoint Greeter } }

    get(api, "/api/p2-greet/x").body.should eq "GET /api/p2-greet/me"
    get(admin, "/admin/p2-greet/x").body.should eq "GET /admin/p2-greet/me"
    get(admin, "/api/p2-greet/x").status_code.should eq 404
    get(api, "/p2-greet/x").status_code.should eq 404
    get(api, "/api/p2-greet", "POST").body.should eq "POST /api/p2-greet/me"
  end

  it "registers the type unprefixed with a bare endpoint call" do
    app = Azu::App.new
    app.routes { endpoint Greeter }
    app.router.registered_routes.map(&.path).should contain "/p2-greet/:name"
  end

  it "leaves App.default serving every macro-declared endpoint, without any registration call" do
    paths = Azu::App.default.router.registered_routes.map { |route| {route.method.to_s.upcase, route.path} }
    paths.should contain({"GET", "/p2-greet/:name"})
    paths.should contain({"POST", "/p2-greet"})
    Azu.with_config(Azu::CONFIG) { Greeter.path(name: "z").should eq "/p2-greet/z" }
  end

  it "starts a new app without routes, whatever endpoint types are declared" do
    isolated = Azu::App.new
    isolated.router.registered_routes.should be_empty
  end

  it "keeps routes per type: sibling subclasses never see each other's" do
    Base.routes.should be_empty
    One.routes.should eq [{"get", "/p2-one"}]
    Two.routes.should eq [{"get", "/p2-two"}, {"post", "/p2-two"}]
  end

  it "refuses to register a type that declares no routes" do
    expect_raises(ArgumentError, /declares no routes/) { Azu::App.new.routes { endpoint Base } }
  end

  it "raises for a verb the router does not know" do
    expect_raises(ArgumentError, /unknown HTTP verb/) { Azu::Router.new.register("yank", "/x", Noop.new) }
  end

  # A verb macro run once the app serves (`Greeter.get "/late"`) would leave a declaration that every later request
  # of App.default tries to apply, and fails on: it is refused where it is declared instead.
  it "refuses a declaration at the declaring call once the router it goes to is frozen" do
    frozen = Azu::Router.new
    frozen.freeze

    expect_raises(Azu::Router::Frozen, "GET /late: a router takes no routes once its app is serving") do
      Azu::DeclaredEndpoints.declare(->(_router : Azu::Router) { nil }, "GET /late", into: frozen)
    end
  end
end
