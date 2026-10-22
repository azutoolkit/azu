require "../spec_helper"
require "http/client"

private struct WhoAmI
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "#{Azu.current_config.env}:#{Azu.current_config.upload.max_file_size}"
    context
  end
end

private def build_app(env : Azu::Environment, limit : UInt64, path : String) : Azu::App
  app = Azu::App.new
  app.config.env = env
  app.config.upload.max_file_size = limit
  app.router.get path, WhoAmI.new
  app
end

private def serve(app : Azu::App, &)
  server = app.server([Azu::Handler::RequestId.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

describe Azu::App do
  it "serves two apps in one process, each with its own routes and configuration" do
    first = build_app(Azu::Environment::Production, 111_u64, "/first")
    second = build_app(Azu::Environment::Test, 222_u64, "/second")

    serve(first) do |one|
      serve(second) do |two|
        one.get("/first").body.should eq "Production:111"
        two.get("/second").body.should eq "Test:222"
        one.get("/second").status_code.should eq 404
        two.get("/first").status_code.should eq 404
      end
    end
  end

  it "leaves the global configuration alone" do
    before = Azu::CONFIG.env

    serve(build_app(Azu::Environment::Production, 1_u64, "/x")) { |client| client.get("/x") }

    Azu::CONFIG.env.should eq before
  end

  it "wraps the global configuration for the default app" do
    Azu::App.default.config.should be Azu::CONFIG
    Azu::App.default.router.should be Azu::CONFIG.router
  end
end
