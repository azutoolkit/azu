require "../../spec_helper"
require "../../../src/azu/dev/dev"

# Config under which request monitoring is on, with its own metrics.
private def monitored_config : Azu::Configuration
  config = Azu::Configuration.new
  config.performance_enabled = true
  config
end

describe "azu/dev instrumentation" do
  it "records cache operations of the current configuration's metrics" do
    config = monitored_config
    manager = Azu::Cache::Manager.new

    Azu.with_config(config) do
      manager.fetch("report") { "1" }
      manager.fetch("report") { "1" }
    end

    recent = config.performance_monitor.not_nil!.metrics.recent_caches(10)
    recent.map { |metric| {metric.operation, metric.hit?} }.should eq [{"get", false}, {"set", false}, {"get", true}]
  end

  it "records nothing while request monitoring is off" do
    config = Azu::Configuration.new
    config.performance_enabled = false
    global = Azu::CONFIG.performance_monitor.try(&.metrics.recent_caches(100).size)

    Azu.with_config(config) { Azu::Cache::Manager.new.set("k", "v") }

    config.performance_monitor.should be_nil
    Azu::CONFIG.performance_monitor.try(&.metrics.recent_caches(100).size).should eq global
  end

  it "gates subscribers on the current configuration's performance_enabled?" do
    off = Azu::Configuration.new.tap { |config| config.performance_enabled = false }
    reported = 0

    Azu::Instrumentation.isolate do
      Azu::Instrumentation.on_cache(-> { Azu::Dev.monitoring? }) { |_| reported += 1 }
      manager = Azu::Cache::Manager.new
      Azu.with_config(off) { manager.set("k", "v") }
      reported.should eq 0
      Azu.with_config(monitored_config) { manager.set("k", "v") }
      reported.should eq 1
    end
  end

  it "records component steps" do
    config = monitored_config

    Azu.with_config(config) do
      Azu::Instrumentation.component("c1", "Counter", "mount", Time.utc) { }
    end

    metric = config.performance_monitor.not_nil!.metrics.recent_components(1).first
    {metric.component_id, metric.component_type, metric.event}.should eq({"c1", "Counter", "mount"})
  end

  describe "lifecycle" do
    it "starts the profiler and the memory monitor in prepare, and stops the monitor it started in finalize" do
      detector = Azu::DevelopmentTools.memory_detector
      profiler = Azu::DevelopmentTools.profiler
      profiler_before = profiler.enabled
      begin
        profiler.enabled = false
        config = Azu::Configuration.new
        config.performance_profiling_enabled = true
        config.performance_memory_monitoring = true

        Azu::Instrumentation.prepare(config)
        profiler.enabled.should be_true
        config.memory_monitor_started?.should be_true

        Azu::Instrumentation.finalize(config)
      ensure
        detector.stop_monitoring
        profiler.enabled = profiler_before
      end
    end

    it "leaves the process-wide monitor alone when another configuration did not start it" do
      config = Azu::Configuration.new
      config.memory_monitor_started?.should be_false
      Azu::Instrumentation.finalize(config) # would raise or stop the monitor if it ignored the flag
    end

    it "follows the environment until the profiler is configured explicitly" do
      config = Azu::Configuration.new
      config.performance_profiling_enabled = nil
      config.env = Azu::Environment::Production
      config.performance_profiling_enabled?.should be_false
      config.env = Azu::Environment::Development
      config.performance_profiling_enabled?.should be_true
      config.performance_profiling_enabled = false
      config.performance_profiling_enabled?.should be_false
    end
  end
end
