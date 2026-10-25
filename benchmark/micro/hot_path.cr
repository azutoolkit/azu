require "./harness"

# In-process hot path of each stack: no socket, no load generator. See "In-process hot path" in benchmark/README.md.
#   crystal build --release --no-debug benchmark/micro/hot_path.cr -o bin/hot_path && bin/hot_path
Log.setup(:none)

# ns/req is the wall time of the whole measurement (setup, warmup and windows) over the requests it drives: it includes
# the first request's lazy initialisation, so it is for same-session comparison only.
private def report(stack : HotPath::Stack, scenario : String, requests : Int32, & : -> Float64) : Nil
  bytes = 0.0
  elapsed = Time.measure { bytes = yield }
  puts "%-8s %-24s %10.1f %10.0f" % [stack.to_s.underscore.tr("_", "-"), scenario, bytes, elapsed.total_nanoseconds / requests]
end

build = {{ flag?(:release) ? "release" : "debug" }}
puts "azu hot path: #{build} build, Crystal #{Crystal::VERSION}"
puts "bytes are exact and repeatable, ns are noisy: compare ns only within one session"
puts "%-8s %-24s %10s %10s" % {"stack", "scenario", "bytes/req", "ns/req"}

[HotPath::Stack::Baseline, HotPath::Stack::AzuMin, HotPath::Stack::Azu].each do |stack|
  {"/plaintext", HotPath::RESOURCE_PATH}.each do |path|
    report(stack, path, HotPath::REQUESTS_DRIVEN) { HotPath.bytes_per_request(stack, path) }
  end
  report(stack, "routing (cycling)", HotPath::ROUTING_REQUESTS_DRIVEN) { HotPath.bytes_per_routing_request(stack) }
end
