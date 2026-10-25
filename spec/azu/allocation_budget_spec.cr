require "../spec_helper"
require "../../benchmark/micro/harness"

# Budgets are bytes per request over the baseline handler, measured in this build plus about 10%,
# and lowered by every slice that saves bytes.
PLAINTEXT_AZU_BUDGET = 2728

private def bytes_over_baseline(stack : Symbol, path : String) : Float64
  HotPath.bytes_per_request(stack, path) - HotPath.bytes_per_request(:baseline, path)
end

describe "allocation budget" do
  {% if flag?(:preview_mt) %}
    # GC.stats.total_bytes counts every thread, so a window would include the other workers' garbage
    pending "keeps the default stack on /plaintext within its budget over the baseline"
    pending "measures a framework cost above the baseline"
  {% else %}
    it "keeps the default stack on /plaintext within its budget over the baseline" do
      extra = bytes_over_baseline(:azu, "/plaintext")

      extra.should be <= PLAINTEXT_AZU_BUDGET
    end

    it "measures a framework cost above the baseline" do
      # A broken harness that reports 0 for every stack would otherwise pass the budget
      HotPath.bytes_per_request(:baseline, "/plaintext").should be > 0
      bytes_over_baseline(:azu, "/plaintext").should be > 0
    end
  {% end %}
end
