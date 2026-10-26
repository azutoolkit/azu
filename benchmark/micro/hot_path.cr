require "./harness"

# In-process hot path of each stack: no socket, no load generator. See "In-process hot path" in benchmark/README.md.
#   mkdir -p bin && crystal build --release --no-debug benchmark/micro/hot_path.cr -o bin/hot_path && bin/hot_path
Log.setup(:none)

private def report(stack : HotPath::Stack, scenario : String, measurement : HotPath::Measurement) : Nil
  puts "%-8s %-24s %10.1f %10.0f" % [stack.to_s.underscore.tr("_", "-"), scenario, measurement.bytes, measurement.ns]
end

build = {{ flag?(:release) ? "release" : "debug" }}
puts "azu hot path: #{build} build, Crystal #{Crystal::VERSION}"
puts "bytes repeat to about 0.3% (GC byte counting granularity); ns move with the machine"
puts "inputs differ by scenario: compare ns with the baseline row or the same row of another commit"
puts "%-8s %-24s %10s %10s" % {"stack", "scenario", "bytes/req", "ns/req"}

[HotPath::Stack::Baseline, HotPath::Stack::AzuMin, HotPath::Stack::Azu].each do |stack|
  {"/plaintext", HotPath::RESOURCE_PATH, HotPath::TEMPLATE_PATH}.each do |path|
    report(stack, path, HotPath.measure(stack, path))
  end
  # The hand-written baseline has no request variables to render with
  report(stack, HotPath::REQUEST_TEMPLATE_PATH, HotPath.measure(stack, HotPath::REQUEST_TEMPLATE_PATH)) unless stack.baseline?
  report(stack, "routing (cycling)", HotPath.measure_routing(stack))
end
