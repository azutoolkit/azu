require "../spec_helper"
require "../../src/azu/testing/testing"

private struct Link
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "#{Azu.mounted_path(Link)}|#{context.request.path}"
    context
  end
end

private struct LoginRequest
  include Azu::Request

  def initialize
  end
end

private struct LoginResponse
  include Azu::Response

  def render
    "login"
  end
end

# Declared with the macro, so it is routed on the global app, not on the apps in these specs.
private struct LoginEndpoint
  include Azu::Endpoint(LoginRequest, LoginResponse)
  get "/app_routes_login"

  def call : LoginResponse
    LoginResponse.new
  end
end

private struct Raises
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    raise "boom"
  end
end

private struct Query
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << "#{context.request.path}?#{context.request.query_params["a"]?}"
    context
  end
end

private struct ShowLogin
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << LoginEndpoint.path
    context
  end
end

private def fetch(app : Azu::App, path : String, method : String = "GET") : Azu::Testing::Response
  Azu::Testing::Client.new(app, [] of HTTP::Handler).request(method, path)
end

describe Azu::App do
  describe "#routes" do
    it "registers explicit routes and prefixes the ones in a scope" do
      app = Azu::App.new
      app.routes do
        get "/ping", Link
        scope "/api" do
          get "/ping", Link
          scope "/v1" do
            post "/ping", Link
          end
        end
      end

      fetch(app, "/ping").status_code.should eq 200
      fetch(app, "/api/ping").status_code.should eq 200
      fetch(app, "/api/v1/ping", "POST").status_code.should eq 200
      fetch(app, "/api/v1/ping").status_code.should eq 404
      fetch(app, "/v1/ping", "POST").status_code.should eq 404
    end

    it "raises on a duplicate route in a scope" do
      app = Azu::App.new
      expect_raises(Azu::Router::DuplicateRoute) do
        app.routes do
          scope("/a") { get "/x", Link }
          get "/a/x", Link
        end
      end
    end
  end

  describe "mounting" do
    it "serves a child app below its prefix with its own configuration, and strips the prefix" do
      admin = Azu::App.new
      admin.config.env = Azu::Environment::Test
      admin.routes { get "/ping", Link }

      main = Azu::App.new
      main.routes do
        get "/ping", Link
        mount admin, at: "/admin"
      end

      fetch(main, "/admin/ping").body.should eq "/admin/ping|/ping"
      fetch(main, "/ping").body.should eq "/ping|/ping"
      fetch(main, "/admin/nope").status_code.should eq 404
    end

    it "gives the endpoint links of a mounted app the prefix, also when the same endpoint is mounted twice" do
      first = Azu::App.new
      first.routes { get "/ping", Link }
      second = Azu::App.new
      second.routes { get "/ping", Link }

      main = Azu::App.new
      main.routes do
        mount first, at: "/a"
        mount second, at: "/b"
      end

      fetch(main, "/a/ping").body.should start_with "/a/ping|"
      fetch(main, "/b/ping").body.should start_with "/b/ping|"
    end

    it "prefixes nested mounts with every level, whichever was mounted first" do
      leaf = Azu::App.new
      leaf.routes { get "/ping", Link }
      middle = Azu::App.new
      middle.routes { mount leaf, at: "/leaf" }
      main = Azu::App.new
      main.routes { mount middle, at: "/mid" }

      fetch(main, "/mid/leaf/ping").body.should eq "/mid/leaf/ping|/ping"
    end

    it "leaves links to endpoints of another app alone" do
      admin = Azu::App.new
      admin.routes { get "/login", ShowLogin }
      main = Azu::App.new
      main.routes { mount admin, at: "/admin" }

      fetch(main, "/admin/login").body.should eq "/app_routes_login"
    end

    it "passes the query string and tolerates trailing slashes" do
      child = Azu::App.new
      child.routes { get "/q", Query }
      main = Azu::App.new
      main.routes { mount child, at: "/admin/" }

      fetch(main, "/admin/q?a=1").body.should eq "/q?1"
      fetch(main, "/admin/q/?a=2").body.should eq "/q/?2"
    end

    it "restores the request path when the child raises" do
      child = Azu::App.new
      child.routes { get "/boom", Raises }
      main = Azu::App.new
      main.routes { mount child, at: "/admin" }
      request = HTTP::Request.new("GET", "/admin/boom")
      context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))

      expect_raises(Exception, "boom") { main.router.process(context) }
      request.path.should eq "/admin/boom"
      Azu.current_config.should be Azu::CONFIG
    end

    it "rejects a mount path that is not a sub path" do
      expect_raises(ArgumentError) { Azu::App.new.routes { mount Azu::App.new, at: "/" } }
    end

    it "refuses to mount one app twice" do
      child = Azu::App.new
      main = Azu::App.new
      main.routes { mount child, at: "/a" }
      expect_raises(ArgumentError) { main.routes { mount child, at: "/b" } }
    end
  end
end
