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

  describe ".generate_id" do
    it "has the form req_<unix ms>_<16 hex digits>" do
      before = Time.utc.to_unix_ms
      id = Azu::RequestContext.generate_id
      id.should match(/\Areq_(\d+)_[0-9a-f]{16}\z/)
      id.split('_')[1].to_i64.should be >= before
    end

    it "refuses a number of random bytes it cannot serve" do
      expect_raises(ArgumentError) { Azu::RequestContext.generate_id(0) }
      expect_raises(ArgumentError) { Azu::RequestContext.generate_id(513) }
      expect_raises(ArgumentError) { Azu::RequestContext.generate_id(-1) }
    end

    it "takes the number of random bytes asked for" do
      Azu::RequestContext.generate_id(4).should match(/\Areq_\d+_[0-9a-f]{8}\z/)
    end

    it "does not repeat across refills of the random chunk, and is not sequential" do
      ids = Array.new(5000) { Azu::RequestContext.generate_id }
      ids.uniq.size.should eq 5000
      suffixes = ids.map { |id| id.split('_').last.to_u64(16) }
      suffixes.each_cons(2).count { |pair| pair[1] == pair[0] + 1 }.should eq 0
    end

    it "gives every fiber its own ids when requests run at once" do
      done = Channel(Array(String)).new
      8.times { spawn { done.send(Array.new(500) { Azu::RequestContext.generate_id }) } }
      all = Array.new(8) { done.receive }.flatten
      all.uniq.size.should eq 4000
    end
  end

  it "names a request without an id from the same generator" do
    context, _io = create_context("GET", "/users")
    Azu::RequestContext.scope(context) { |info| info.request_id.should match(/\Areq_\d+_[0-9a-f]{8}\z/) }
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
