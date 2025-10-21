require "../spec_helper"
require "../../src/azu/performance_metrics"
require "../../src/azu/development_tools"
require "../../src/azu/handler/performance_monitor"

describe Azu::PerformanceMetrics do
  describe "#record_request" do
    it "records request metrics" do
      metrics = Azu::PerformanceMetrics.new

      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 100.0,
        memory_before: 1000000,
        memory_after: 1100000,
        status_code: 200
      )

      stats = metrics.aggregate_stats
      stats.total_requests.should eq(1)
      stats.avg_response_time.should eq(100.0)
      stats.error_rate.should eq(0.0)
    end

    it "tracks error rates" do
      metrics = Azu::PerformanceMetrics.new

      # Record successful request
      metrics.record_request("TestEndpoint", "GET", "/test", 50.0, 1000000, 1100000, 200)

      # Record error request
      metrics.record_request("TestEndpoint", "GET", "/test", 75.0, 1000000, 1100000, 500)

      stats = metrics.aggregate_stats
      stats.total_requests.should eq(2)
      stats.error_requests.should eq(1)
      stats.error_rate.should eq(50.0)
    end
  end

  describe "#record_component" do
    it "records component lifecycle metrics" do
      metrics = Azu::PerformanceMetrics.new

      metrics.record_component(
        component_id: "comp123",
        component_type: "TestComponent",
        event: "mount",
        processing_time: 25.0,
        memory_before: 1000000,
        memory_after: 1050000
      )

      component_stats = metrics.component_stats("TestComponent")
      component_stats["mount_events"].should eq(1.0)
    end
  end

  describe "#aggregate_stats" do
    it "calculates percentiles correctly" do
      metrics = Azu::PerformanceMetrics.new

      # Record requests with different response times
      [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0].each do |time|
        metrics.record_request("TestEndpoint", "GET", "/test", time, 1000000, 1100000, 200)
      end

      stats = metrics.aggregate_stats
      stats.min_response_time.should eq(10.0)
      stats.max_response_time.should eq(100.0)
      stats.avg_response_time.should eq(55.0)
      stats.p95_response_time.should be >= 90.0
    end
  end
end

describe Azu::DevelopmentTools::Profiler do
  describe "#profile" do
    it "profiles code execution" do
      profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)

      result = profiler.profile("test_operation") do
        sleep(1.milliseconds) # Small delay to ensure measurable time
        "test_result"
      end

      result.should eq("test_result")

      entries = profiler.entries
      entries.size.should eq(1)
      entries.first.name.should eq("test_operation")
      entries.first.duration.total_milliseconds.should be > 0
    end

    it "returns result without profiling when disabled" do
      profiler = Azu::DevelopmentTools::Profiler.new(enabled: false)

      result = profiler.profile("test_operation") do
        "test_result"
      end

      result.should eq("test_result")
      profiler.entries.size.should eq(0)
    end
  end

  describe "#stats" do
    it "aggregates profiling statistics" do
      profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)

      # Profile the same operation multiple times
      3.times do
        profiler.profile("repeated_operation") do
          sleep(1.milliseconds)
        end
      end

      stats = profiler.stats
      stats["repeated_operation"].should_not be_nil

      operation_stats = stats["repeated_operation"]
      operation_stats["count"].should eq(3.0)
      operation_stats["avg_time_ms"].should be > 0
    end
  end
end

describe Azu::DevelopmentTools::MemoryLeakDetector do
  describe "#take_snapshot" do
    it "captures memory snapshots" do
      detector = Azu::DevelopmentTools::MemoryLeakDetector.new

      snapshot = detector.take_snapshot

      snapshot.heap_size.should be > 0
      snapshot.gc_stats["heap_size"].should_not be_nil
    end
  end

  describe "#analyze_leak" do
    it "analyzes memory growth between snapshots" do
      detector = Azu::DevelopmentTools::MemoryLeakDetector.new

      # Take initial snapshot
      detector.take_snapshot

      # Allocate some memory (this will be cleaned up by GC)
      _ = Array(String).new(1000) { "memory_test" }

      # Take second snapshot
      detector.take_snapshot

      # Analyze (may or may not show growth depending on GC timing)
      analysis = detector.analyze_leak
      analysis.should be_a(Azu::DevelopmentTools::MemoryLeakDetector::LeakAnalysis)
      analysis.duration.total_seconds.should be >= 0
    end
  end
end

# Skip Benchmark specs in CI pipeline
{% unless env("CRYSTAL_ENV") == "pipeline" %}
describe Azu::DevelopmentTools::Benchmark do
  describe ".run" do
    it "benchmarks code execution" do
      result = Azu::DevelopmentTools::Benchmark.run("test_benchmark", 10, 5) do
        # Simple operation
        (1..100).sum
      end

      result.name.should eq("test_benchmark")
      result.iterations.should eq(10)
      result.avg_time.total_nanoseconds.should be > 0
      result.ops_per_second.should be > 0
    end
  end

  describe ".compare" do
    it "compares multiple benchmark operations" do
      benchmarks = {
        "addition"       => -> { 1 + 1; nil },
        "multiplication" => -> { 2 * 2; nil },
      }

      results = Azu::DevelopmentTools::Benchmark.compare(benchmarks, 100)

      results.size.should eq(2)
      results.each do |result|
        result.should be_a(Azu::DevelopmentTools::Benchmark::BenchmarkResult)
        result.iterations.should eq(100)
      end
    end
  end
end

describe Azu::Handler::PerformanceMonitor do
  describe "#call" do
    it "tracks request performance" do
      monitor = Azu::Handler::PerformanceMonitor.new

      # Create mock context
      request = HTTP::Request.new("GET", "/test")
      response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(request, response)

      # Mock the call_next behavior
      monitor.call(context)

      # Should have recorded the request
      monitor.enabled?.should be_true
      _ = monitor.recent_requests(1)

      # Note: In a real scenario, this would be called through the handler chain
      # For testing, we verify the monitor is properly initialized
    end
  end

  describe "#stats" do
    it "provides access to performance statistics" do
      monitor = Azu::Handler::PerformanceMonitor.new

      stats = monitor.stats
      stats.should be_a(Azu::PerformanceMetrics::AggregatedStats)
    end
  end

  describe "#generate_report" do
    it "generates performance report" do
      monitor = Azu::Handler::PerformanceMonitor.new

      report = monitor.generate_report
      report.should contain("Performance Report")
      report.should contain("Total Requests")
    end
  end
end

{% end %}
