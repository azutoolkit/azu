require "../spec_helper"
require "../../benchmark/micro/harness"

# Bytes per request over the baseline handler. Each budget is the whole-suite `crystal spec` measurement plus ~10%,
# rounded up to a multiple of 8 (measured 2643 / 1918 / 3420 / 2677, in the order below; a single-file run measures
# ~100 B less). Re-measure and lower them when a slice saves bytes or a new Crystal shifts stdlib allocations.
# A single-file run measures less because per-request bytes depend on the compiled program (`Azu::Router::Route`
# inlines a union of every compiled Routable, so its size grows with the endpoint types in the build): the budgets
# are calibrated on the whole-suite file list.
PLAINTEXT_AZU_BUDGET     = 2912
PLAINTEXT_AZU_MIN_BUDGET = 2112
RESOURCE_AZU_BUDGET      = 3768
RESOURCE_AZU_MIN_BUDGET  = 2952

private def bytes_over_baseline(stack : HotPath::Stack, path : String) : Float64
  HotPath.measure(stack, path).bytes - HotPath.measure(HotPath::Stack::Baseline, path).bytes
end

describe "allocation budget" do
  it "answers /plaintext with the body on every stack it measures" do
    HotPath::Stack.each do |stack|
      response = HotPath.response(stack, "/plaintext")

      response.should start_with("HTTP/1.1 200")
      response.should end_with(HotPath::BODY)
    end
  end

  it "answers the param route with its JSON body on every stack it measures" do
    HotPath::Stack.each do |stack|
      response = HotPath.response(stack, HotPath::RESOURCE_PATH)

      response.should start_with("HTTP/1.1 200")
      response.should end_with(HotPath::RESOURCE_BODY)
    end
  end

  it "keeps the connection alive across requests on every stack it measures" do
    HotPath::Stack.each do |stack|
      ["/plaintext", HotPath::RESOURCE_PATH].each do |path|
        # One 200 per request: a stack that closes the connection or errors after the first would measure cheap
        HotPath.response(stack, path, count: 3).scan("HTTP/1.1 200").size.should eq 3
      end
    end
  end

  it "mirrors routing.lua's URLs" do
    lua = File.read(Path[__DIR__, "../../benchmark/driver/routing.lua"])
    {"n % 100", "n % 997", "n = n + 1"}.each { |formula| lua.should contain formula }

    HotPath.routing_path(1).should eq "/api/v1/resource1/1"
    HotPath.routing_path(1234).should eq "/api/v1/resource34/237"
    HotPath.routing_path(997).should eq "/api/v1/resource97/0"
  end

  it "warms the routing scenario past the path cache, then measures only paths new to the router" do
    warmup, *measured = HotPath.routing_windows

    warmup.begin.should eq 1 # routing.lua increments n before its first request
    # More paths than the router's path cache holds (Router::PathCache::DEFAULT_MAX_SIZE, 1000), so it is full
    warmup.map { |n| HotPath.routing_path(n) }.uniq.size.should be > 1000
    measured.size.should eq HotPath::WINDOWS
    HotPath.routing_windows.each_cons_pair { |earlier, later| later.begin.should be > earlier.end }
    # Disjoint numbers give new paths only within one cycle of the URL formula
    paths = HotPath.routing_windows.flat_map(&.to_a).map { |n| HotPath.routing_path(n) }
    paths.uniq.size.should eq paths.size
  end

  it "measures bytes and nanoseconds per request" do
    measurement = HotPath.measure(HotPath::Stack::Baseline, "/plaintext")

    measurement.bytes.should be > 0
    measurement.ns.should be > 0
  end

  it "answers cycling routing URLs on every stack" do
    HotPath::Stack.each do |stack|
      response = HotPath.response(stack, HotPath.routing_path(1234))

      response.should start_with("HTTP/1.1 200")
      response.should end_with(%({"route":"resource","id":"237"}))
    end
  end

  {% if flag?(:preview_mt) %}
    # GC.stats.total_bytes counts every thread, so a window would include the other workers' garbage
    pending "keeps the default stack on /plaintext within its budget over the baseline"
    pending "keeps azu-min on /plaintext within its budget over the baseline"
    pending "keeps the default stack on the param route within its budget over the baseline"
    pending "keeps azu-min on the param route within its budget over the baseline"
    pending "measures a baseline that parses a request and writes a response"
    pending "measures a framework cost above the baseline"
    pending "measures the cycling routing scenario"
    pending "measures nothing for a block that allocates nothing"
    pending "measures what a block allocates"
  {% else %}
    it "keeps the default stack on /plaintext within its budget over the baseline" do
      bytes_over_baseline(HotPath::Stack::Azu, "/plaintext").should be <= PLAINTEXT_AZU_BUDGET
    end

    it "keeps azu-min on /plaintext within its budget over the baseline" do
      bytes_over_baseline(HotPath::Stack::AzuMin, "/plaintext").should be <= PLAINTEXT_AZU_MIN_BUDGET
    end

    it "keeps the default stack on the param route within its budget over the baseline" do
      bytes_over_baseline(HotPath::Stack::Azu, HotPath::RESOURCE_PATH).should be <= RESOURCE_AZU_BUDGET
    end

    it "keeps azu-min on the param route within its budget over the baseline" do
      bytes_over_baseline(HotPath::Stack::AzuMin, HotPath::RESOURCE_PATH).should be <= RESOURCE_AZU_MIN_BUDGET
    end

    it "measures a baseline that parses a request and writes a response" do
      # A harness that processes nothing reports ~16 B, which would let every budget pass
      HotPath.measure(HotPath::Stack::Baseline, "/plaintext").bytes.should be >= 300
    end

    it "measures a framework cost above the baseline" do
      bytes_over_baseline(HotPath::Stack::Azu, "/plaintext").should be > 0
    end

    it "measures the cycling routing scenario" do
      bytes = HotPath::Stack.values.to_h { |stack| {stack, HotPath.measure_routing(stack).bytes} }

      bytes.each_value { |per_request| per_request.should be > 0 }
      # A framework costs more than a hand-written dispatch, also while the router's path cache is full
      bytes[HotPath::Stack::Azu].should be > bytes[HotPath::Stack::Baseline]
    end

    it "measures nothing for a block that allocates nothing" do
      HotPath.bytes_per_call { }.should be < 1
    end

    it "measures what a block allocates" do
      # The positive control: without it the helper could report 0 for everything and still pass the check above
      HotPath.bytes_per_call { "x" * 200 }.should be >= 200
    end
  {% end %}
end
