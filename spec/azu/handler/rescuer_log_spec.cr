require "../../spec_helper"
require "log/spec"

# One request, one log entry: a 4xx is the client's mistake, so it is not an error, carries no exception and is
# written by exactly one place. Only a 5xx or an unexpected exception is logged at error level with its backtrace.
private def run_chain(path : String = "/x", &app : HTTP::Server::Context -> Nil) : HTTP::Server::Context
  chain = HTTP::Server.build_middleware([Azu::Handler::Rescuer.new] of HTTP::Handler, app)
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(IO::Memory.new))
  chain.call(context)
  context.response.flush
  context
end

describe "request error logging" do
  it "logs a route that does not exist once, below error level, without an exception" do
    router = Azu::Router.new
    Log.capture("*") do |logs|
      context = run_chain("/missing") { |c| router.process(c); nil }
      context.response.status_code.should eq 404

      logs.next(:debug, /404.*GET \/missing|GET \/missing.*404/)
      logs.entry.exception.should be_nil
      logs.empty
    end
  end

  it "logs a NotFound raised by an endpoint once, below error level, without an exception" do
    Log.capture("*") do |logs|
      context = run_chain("/users/9") { |_| raise Azu::Response::NotFound.new("/users/9") }
      context.response.status_code.should eq 404

      logs.next(:debug, /404.*GET \/users\/9|GET \/users\/9.*404/)
      logs.entry.exception.should be_nil
      logs.empty
    end
  end

  it "logs other 4xx errors below error level too" do
    Log.capture("*") do |logs|
      context = run_chain { |_| raise Azu::Response::BadRequest.new("bad") }
      context.response.status_code.should eq 400

      logs.next(:debug, /400/)
      logs.entry.exception.should be_nil
      logs.empty
    end
  end

  it "logs a 5xx Response::Error at error level with the exception" do
    Log.capture("*") do |logs|
      context = run_chain { |_| raise Azu::Response::DatabaseError.new("boom") }
      context.response.status_code.should eq 500

      logs.next(:error, /500/)
      logs.entry.exception.should be_a Azu::Response::DatabaseError
      logs.empty
    end
  end

  it "logs an unexpected exception at error level with the exception" do
    Log.capture("*") do |logs|
      context = run_chain { |_| raise "unexpected" }
      context.response.status_code.should eq 500

      logs.next(:error, /./)
      logs.entry.exception.try(&.message).should eq "unexpected"
      logs.empty
    end
  end
end
