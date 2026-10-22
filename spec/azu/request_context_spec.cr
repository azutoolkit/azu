require "../spec_helper"
require "../support/integration_helpers"

include IntegrationHelpers

describe Azu::RequestContext do
  it "is empty outside a scope" do
    Azu::RequestContext.current?.should be_nil
  end

  it "registers the request for the current fiber and cleans up" do
    context, _io = create_context("GET", "/users", HTTP::Headers{"X-Request-ID" => "req-abc"})
    Azu::RequestContext.scope(context) do |info|
      info.request_id.should eq "req-abc"
      Azu::RequestContext.current?.should be(info)
      info.endpoint = "UsersEndpoint"
    end
    Azu::RequestContext.current?.should be_nil
  end

  it "reuses an outer scope" do
    context, _io = create_context("GET", "/users")
    Azu::RequestContext.scope(context) do |outer|
      Azu::RequestContext.scope(context) { |inner| inner.should be(outer) }
      Azu::RequestContext.current?.should be(outer)
    end
  end

  it "is isolated per fiber" do
    seen = Channel(String?).new
    Azu::RequestContext.with("main") do
      spawn { seen.send(Azu::RequestContext.current?.try(&.request_id)) }
      seen.receive.should be_nil
      Azu::RequestContext.current?.try(&.request_id).should eq "main"
    end
  end

  it "restores the previous context after with" do
    Azu::RequestContext.with("outer") do
      Azu::RequestContext.with("inner") { Azu::RequestContext.current?.not_nil!.request_id.should eq "inner" }
      Azu::RequestContext.current?.not_nil!.request_id.should eq "outer"
    end
  end
end
