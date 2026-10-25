require "../spec_helper"
require "../../benchmark/micro/harness"

# Bytes per request over the baseline handler: measured 2530 B, plus 10% headroom, rounded up to a multiple of 8.
# Re-measure and lower when a slice saves bytes or a new Crystal shifts stdlib allocations.
PLAINTEXT_AZU_BUDGET = 2784

private def bytes_over_baseline(stack : HotPath::Stack, path : String) : Float64
  HotPath.bytes_per_request(stack, path) - HotPath.bytes_per_request(HotPath::Stack::Baseline, path)
end

describe "allocation budget" do
  it "answers /plaintext with the body on every stack it measures" do
    HotPath::Stack.each do |stack|
      response = HotPath.response(stack, "/plaintext")

      response.should start_with("HTTP/1.1 200")
      response.should end_with(HotPath::BODY)
    end
  end

  {% if flag?(:preview_mt) %}
    # GC.stats.total_bytes counts every thread, so a window would include the other workers' garbage
    pending "keeps the default stack on /plaintext within its budget over the baseline"
    pending "measures a framework cost above the baseline"
  {% else %}
    it "keeps the default stack on /plaintext within its budget over the baseline" do
      bytes_over_baseline(HotPath::Stack::Azu, "/plaintext").should be <= PLAINTEXT_AZU_BUDGET
    end

    it "measures a framework cost above the baseline" do
      # A broken harness that reports 0 for every stack would otherwise pass the budget
      HotPath.bytes_per_request(HotPath::Stack::Baseline, "/plaintext").should be > 0
      bytes_over_baseline(HotPath::Stack::Azu, "/plaintext").should be > 0
    end
  {% end %}
end
