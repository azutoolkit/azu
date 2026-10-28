require "spec"
require "../src/app"

# These are disposable test values, generated anew and never printed.
ENV["SESSION_SECRET"] = Random::Secure.hex(32)
ENV["CSRF_SECRET"] = Random::Secure.hex(32)

module SessionIntegration
  class_property handler : HTTP::Handler?
  class_property ids = Set(String).new

  class Client
    property cookie : String? = nil

    def request(path, method = "GET", token : String? = nil)
      headers = HTTP::Headers{"Host" => "localhost", "Accept" => "application/json"}
      headers["Cookie"] = "_session=#{cookie}" if cookie = @cookie
      headers["X-CSRF-TOKEN"] = token if token
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new(method, path, headers), HTTP::Server::Response.new(io))
      SessionIntegration.handler.not_nil!.call(context)
      context.response.close
      response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
      if session = response.cookies["_session"]?
        @cookie = session.value
        SessionIntegration.ids << session.value
      end
      response
    end

    def csrf : String
      response = request("/csrf")
      response.status_code.should eq 200
      JSON.parse(response.body)["csrf"].as_s
    end
  end
end

describe "pooled Redis sessions with Azu error handling" do
  before_all do
    app, handlers = RedisSessionsExample.build
    app.config.env = Azu::Environment::Production
    SessionIntegration.handler = app.dispatcher(handlers)
  end

  after_all do
    # Only delete session IDs created by this suite; never flush the shared Redis.
    SessionIntegration.ids.each { |id| Session.session.delete(id) }
    RedisSessionsExample.pool.try(&.shutdown)
  end

  it "persists a CSRF-protected update and refuses a missing token" do
    client = SessionIntegration::Client.new
    token = client.csrf
    client.request("/visits", "POST").status_code.should eq 403
    client.request("/visits", "POST", token).status_code.should eq 201
    JSON.parse(client.request("/session").body)["visits"].as_i.should eq 1
  end

  it "preserves the session cookie and state across a rendered endpoint exception" do
    client = SessionIntegration::Client.new
    token = client.csrf
    client.request("/visits", "POST", token).status_code.should eq 201
    cookie = client.cookie
    failed = client.request("/failure")
    failed.status_code.should eq 500
    failed.body.should_not contain "example endpoint failure"
    client.cookie.should eq cookie
    JSON.parse(client.request("/session").body)["visits"].as_i.should eq 1
  end

  it "keeps concurrent visitors isolated through the real pooled Redis store" do
    clients = Array.new(2) { SessionIntegration::Client.new }
    clients.each_with_index do |client, index|
      token = client.csrf
      (index + 1).times { client.request("/visits", "POST", token).status_code.should eq 201 }
    end
    results = Channel(Bool).new(40)
    40.times do |index|
      spawn do
        client = SessionIntegration::Client.new
        client.cookie = clients[index % 2].cookie
        begin
          response = client.request("/session")
          results.send(response.status_code == 200 && JSON.parse(response.body)["visits"].as_i == index % 2 + 1)
        rescue
          results.send(false)
        end
      end
    end
    40.times do
      select
      when result = results.receive
        result.should be_true
      when timeout(10.seconds)
        fail "concurrent session request did not complete"
      end
    end
  end
end
