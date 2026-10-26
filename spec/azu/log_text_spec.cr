require "../spec_helper"
require "log/spec"

describe Azu::LogText do
  it "escapes C0 and C1 controls, line separators and bidi overrides" do
    Azu::LogText.safe("a\u0085b c\u202Ed\u2066e\u009f").should eq "a\\x85b\\u2028c\\u202ed\\u2066e\\x9f"
  end

  it "keeps an access-line target up to 2 KB and cuts the short reason text sooner" do
    long = "/search?q=" + "x" * 1500
    Azu::LogText.safe(long).should eq long
    Azu::LogText.safe("y" * 3000).size.should eq 2051
    Azu::LogText.client_error_line("GET", "/" + "z" * 500, 404, "Not Found").size.should be < 260
  end

  it "replaces credential query parameters in the logged target" do
    Azu::LogText.target("/cb?code=abc&token=hunter2&page=2").should eq "/cb?code=abc&token=[FILTERED]&page=2"
  end

  it "keeps them out of the request log lines" do
    backend = Log::MemoryBackend.new
    handler = Azu::Handler::Logger.new(Log.new("spec", backend, Log::Severity::Debug))
    request = HTTP::Request.new("GET", "/cb?token=hunter2&page=2", HTTP::Headers{"X-Azu-Endpoint" => "Endpoint\u2028forged"})
    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
    handler.next = ->(_c : HTTP::Server::Context) { }
    handler.call(context)

    dump = backend.entries.map { |entry| "#{entry.message} #{entry.data}" }.join("\n")
    dump.should_not be_empty
    dump.should_not contain "hunter2"
    dump.should contain "page=2"
    dump.should_not contain "\u2028"
  end

  # The server splits the request line on spaces only, so the method can carry control characters
  it "escapes the method like the path" do
    Azu::LogText.client_error_line("GET\r\nforged", "/", 404, "Not Found").should_not contain "\n"

    request = begin
      HTTP::Request.new("GET\e[2Jforged", "/")
    rescue ArgumentError # newer Crystal versions refuse such a method while parsing: no handler ever logs it there
      nil
    end
    if request
      backend = Log::MemoryBackend.new
      handler = Azu::Handler::Logger.new(Log.new("spec", backend, Log::Severity::Debug))
      handler.next = ->(_c : HTTP::Server::Context) { }
      handler.call(HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new)))

      backend.entries.map(&.message).join.should_not contain "\e[2J"
    end
  end
end
