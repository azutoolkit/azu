require "../spec_helper"
require "http/client"

private struct Link
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "#{Azu.mounted_path(Link)}|#{context.request.path}"
    context
  end
end

private def fetch(app : Azu::App, path : String, method : String = "GET") : HTTP::Client::Response
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    HTTP::Client.new(address.address, address.port).exec(method, path)
  ensure
    server.close
  end
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

    it "refuses to mount one app twice" do
      child = Azu::App.new
      main = Azu::App.new
      main.routes { mount child, at: "/a" }
      expect_raises(ArgumentError) { main.routes { mount child, at: "/b" } }
    end
  end
end
