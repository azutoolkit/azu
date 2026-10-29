require "../spec_helper"

private struct TemplateBodyEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    body = Azu::Helpers::TemplateContext.new(context).body
    context.response << body.try(&.bytesize)
    context
  end
end

describe Azu::Helpers::TemplateContext do
  it "bounds template body reads even when Content-Length is absent" do
    config = Azu::Configuration.new
    config.upload.max_file_size = 16_u64
    input = IO::Memory.new("x" * 1024)
    request = HTTP::Request.new("POST", "/", body: input)
    request.headers.delete("Content-Length")
    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
    Azu.with_config(config) do
      expect_raises(Azu::Response::PayloadTooLarge) { Azu::Helpers::TemplateContext.new(context).body }
    end
    input.pos.should eq 17
  end

  it "accepts a body exactly at the configured limit" do
    config = Azu::Configuration.new
    config.upload.max_file_size = 16_u64
    context = HTTP::Server::Context.new(HTTP::Request.new("POST", "/", body: "x" * 16), HTTP::Server::Response.new(IO::Memory.new))
    Azu.with_config(config) { Azu::Helpers::TemplateContext.new(context).body.should eq "x" * 16 }
  end

  it "closes refused chunked uploads and serves subsequent POSTs without misframing" do
    app = Azu::App.new
    app.config.upload.max_file_size = 1024_u64
    app.routes { post "/body", TemplateBodyEndpoint }
    server = app.server([Azu::Handler::Rescuer.new(Log.for("body-limit-spec", :none))] of HTTP::Handler)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    done = Channel(Exception?).new(64)
    begin
      64.times do
        spawn do
          begin
            HTTP::Client.new(address.address, address.port) do |client|
              client.read_timeout = 10.seconds
              refused = client.post("/body", body: IO::Memory.new("x" * 2048))
              refused.status_code.should eq 413
              refused.headers["Connection"].should eq "close"
              2.times do
                accepted = client.post("/body", body: "x" * 1024)
                accepted.status_code.should eq 200
                accepted.body.should eq "1024"
              end
            end
            done.send(nil)
          rescue ex
            done.send(ex)
          end
        end
      end
      64.times do
        select
        when error = done.receive
          raise error if error
        when timeout(20.seconds)
          fail "concurrent POST requests stalled"
        end
      end
    ensure
      server.close
    end
  end
end
