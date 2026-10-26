require "../spec_helper"
require "../../benchmark/micro/harness"

# Bytes per request over the baseline handler. Each budget is the whole-suite `crystal spec` measurement plus ~10%,
# rounded up to a multiple of 8 (measured 447 / 236 / 949 / 734 with the segment tree, in the order below; 784 / 575 /
# 1328 / 1119 with radix). Re-measure and lower them when a slice saves bytes or a new Crystal shifts stdlib
# allocations. Per-request bytes can depend on the compiled program, so a single-file run may measure less: the
# budgets are calibrated on the whole-suite file list.
PLAINTEXT_AZU_BUDGET     =  496
PLAINTEXT_AZU_MIN_BUDGET =  264
RESOURCE_AZU_BUDGET      = 1048
RESOURCE_AZU_MIN_BUDGET  =  808

private def bytes_over_baseline(stack : HotPath::Stack, path : String) : Float64
  HotPath.measure(stack, path).bytes - HotPath.measure(HotPath::Stack::Baseline, path).bytes
end

module AllocationBudgetSpec
  struct BareEndpoint
    include Azu::Endpoint(Azu::Request, HotPath::Raw)

    def call : HotPath::Raw
      HotPath::Raw.new("ok")
    end
  end

  struct FieldlessEndpoint
    include Azu::Endpoint(HotPath::NoRequest, HotPath::Raw)

    def call : HotPath::Raw
      HotPath::Raw.new("ok")
    end
  end

  module Deeply::Nested::Name::Space
    struct LabelledEndpoint
      include Azu::Endpoint(Azu::Request, HotPath::Raw)

      def call : HotPath::Raw
        HotPath::Raw.new("ok")
      end
    end
  end
end

# One context for every call, so the measured bytes are the endpoint's own (a connection builds its request outside it).
private def endpoint_bytes(endpoint : T) : Float64 forall T
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/items?page=2"), HTTP::Server::Response.new(HotPath::NullIO.new))
  endpoint.call(context)

  HotPath.bytes_per_call do
    context.response.reset
    endpoint.call(context)
  end
end

# What Static falls through to; it answers nothing, so the measured bytes are Static's own.
private class NoopHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
  end
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

  it "warms the routing scenario with more than 1000 paths, then measures only paths new to the router" do
    warmup, *measured = HotPath.routing_windows

    warmup.begin.should eq 1 # routing.lua increments n before its first request
    # More paths than the router's former path cache held (1000), as HotPath::ROUTING_WARMUP_REQUESTS explains
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
    pending "a fieldless contract on a request without a body costs no more than no contract"
    pending "an endpoint's label costs the same whatever its namespace depth"
    pending "the router adds at most 16 B to an endpoint call on a static route"
    pending "Static allocates nothing on a routed path when the public directory does not exist"
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
      # A framework costs more than a hand-written dispatch
      bytes[HotPath::Stack::Azu].should be > bytes[HotPath::Stack::Baseline]
    end

    it "measures nothing for a block that allocates nothing" do
      HotPath.bytes_per_call { }.should be < 1
    end

    it "measures what a block allocates" do
      # The positive control: without it the helper could report 0 for everything and still pass the check above
      HotPath.bytes_per_call { "x" * 200 }.should be >= 200
    end

    it "a fieldless contract on a request without a body costs no more than no contract" do
      bare = endpoint_bytes(AllocationBudgetSpec::BareEndpoint.new)
      fieldless = endpoint_bytes(AllocationBudgetSpec::FieldlessEndpoint.new)

      # Nothing is declared to read or check, and a request without a body has nothing else to parse
      (fieldless - bare).should be <= 16
    end

    it "an endpoint's label costs the same whatever its namespace depth" do
      shallow = endpoint_bytes(AllocationBudgetSpec::BareEndpoint.new)
      deep = endpoint_bytes(AllocationBudgetSpec::Deeply::Nested::Name::Space::LabelledEndpoint.new)

      # The label is known when the endpoint is compiled, so a longer name than BareEndpoint's adds no work per request
      (deep - shallow).should be <= 8
    end

    it "the router adds at most 16 B to an endpoint call on a static route" do
      endpoint = AllocationBudgetSpec::BareEndpoint.new
      router = Azu::Router.new
      router.get "/plaintext", endpoint
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/plaintext"), HTTP::Server::Response.new(HotPath::NullIO.new))
      # The first call sets the X-Azu-Endpoint header, which the measured ones only overwrite
      router.process(context)

      through_router = HotPath.bytes_per_call do
        context.response.reset
        router.process(context)
      end
      endpoint_alone = HotPath.bytes_per_call do
        context.response.reset
        endpoint.call(context)
      end

      # Finding a static route allocates nothing, and what process returns is never read, so it is not formatted
      (through_router - endpoint_alone).should be <= 16
    end

    it "Static allocates nothing on a routed path when the public directory does not exist" do
      static = Azu::Handler::Static.new("/azu-hot-path/no-such-public", fallthrough: true)
      static.next = NoopHandler.new
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/plaintext"), HTTP::Server::Response.new(IO::Memory.new))
      # The first call memoizes request.path, which a connection's request has parsed already
      static.call(context)

      HotPath.bytes_per_call { static.call(context) }.should be < 1
    end
  {% end %}
end

# One render of benchmark/apps/common/template.jinja, compiled as the bench app's (HotPath::COMPILED), on the default
# stack over the baseline's ECR render, calibrated like the budgets above (whole-suite measurement plus ~10%, rounded
# up to a multiple of 8; measured 11024 compiled, 77922 through Crinja).
TEMPLATE_AZU_BUDGET = 12128

describe "allocation budget of a template render" do
  it "answers /template with the bench app's HTML on every stack it measures" do
    # Bench::ITEMS rendered by benchmark/apps/common/template.jinja: the names carry characters that must be escaped
    items = (1..20).join { |i| %(<li class="item-#{i}">Item #{i} &amp; &lt;co&gt; (#{i * 7})</li>) }
    html = %(<!DOCTYPE html><html><head><title>Items</title></head><body><h1>Items</h1><ul>#{items}</ul></body></html>)

    HotPath::Stack.each do |stack|
      response = HotPath.response(stack, "/template")

      response.should start_with("HTTP/1.1 200")
      response.should contain("Content-Type: text/html")
      response.should end_with(html)
    end
  end

  it "renders the bench templates compiled, as the bench app does, none of them falling back to Crinja" do
    HotPath::COMPILED.templates.keys.sort!.should eq ["template.jinja", "template_request.jinja"]
    HotPath::COMPILED.fallbacks.should be_empty
  end

  {% if flag?(:preview_mt) %}
    pending "keeps the default stack on /template within its budget over the baseline"
  {% else %}
    it "keeps the default stack on /template within its budget over the baseline" do
      bytes_over_baseline(HotPath::Stack::Azu, HotPath::TEMPLATE_PATH).should be <= TEMPLATE_AZU_BUDGET
    end
  {% end %}
end

# What rendering the same page with its request adds on the default stack: the request variables (the template reads
# one), the CSRF token and its cookie. Calibrated like the budgets above (measured 34 compiled, 2506 through Crinja).
REQUEST_TEMPLATE_AZU_BUDGET = 40

describe "allocation budget of a template render with its request" do
  it "answers /template/request with the page, the request variable it reads and the CSRF cookie" do
    {HotPath::Stack::AzuMin, HotPath::Stack::Azu}.each do |stack|
      response = HotPath.response(stack, "/template/request")

      response.should start_with("HTTP/1.1 200")
      response.should contain("Set-Cookie: csrf_token=")
      response.should contain("<h1>Items</h1><p>GET</p><ul>")
      response.should end_with("(140)</li></ul></body></html>")
    end
  end

  {% if flag?(:preview_mt) %}
    pending "keeps what the request adds to /template within its budget on the default stack"
  {% else %}
    it "keeps what the request adds to /template within its budget on the default stack" do
      added = HotPath.measure(HotPath::Stack::Azu, "/template/request").bytes - HotPath.measure(HotPath::Stack::Azu, "/template").bytes

      added.should be <= REQUEST_TEMPLATE_AZU_BUDGET
    end
  {% end %}
end
