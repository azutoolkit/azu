require "../../src/azu"
require "../responses/generic_json_response"
require "../requests/empty_request"

module ExampleApp
  # Endpoint to demonstrate development tools features
  struct DevelopmentToolsEndpoint
    include Azu::Endpoint(EmptyRequest, GenericJsonResponse)

    get "/development/tools"

    def call : GenericJsonResponse
      # Demonstrate profiler
      profiler_result = Azu::DevelopmentTools.profile("demo_operation") do
        # Simulate some work
        sleep(0.01.seconds)
        (1..1000).each { |i| i * i }
      end

      # Get profiler stats
      profiler_stats = Azu::DevelopmentTools.profiler.stats
      profiler_report = Azu::DevelopmentTools.profiler.report

      # Get memory leak detector info
      memory_detector = Azu::DevelopmentTools.memory_detector
      memory_snapshots = memory_detector.recent_snapshots(5)
      memory_report = memory_detector.report

      # Run a simple benchmark
      benchmark_result = Azu::DevelopmentTools::Benchmark.run("string_concat", 100) do
        str = ""
        10.times { str += "benchmark" }
      end

      # Compare multiple operations
      comparison_benchmarks = {
        "array_append" => -> {
          arr = [] of String
          10.times { arr << "test" }
          nil
        },
        "string_build" => -> {
          String.build do |str|
            10.times { str << "test" }
          end
          nil
        },
      }

      comparison_results = Azu::DevelopmentTools::Benchmark.compare(comparison_benchmarks, 50)

      data = {
        "profiler" => {
          "enabled"     => Azu::DevelopmentTools.profiler.enabled,
          "stats"       => profiler_stats,
          "report"      => profiler_report,
          "demo_result" => "Profiled operation completed",
        },
        "memory_detector" => {
          "snapshots_count" => memory_snapshots.size,
          "latest_snapshot" => memory_snapshots.last?.try do |snapshot|
            {
              "timestamp"         => snapshot.timestamp.to_rfc3339,
              "heap_size_mb"      => (snapshot.heap_size / 1024.0 / 1024.0).round(2),
              "free_bytes_mb"     => (snapshot.gc_stats["free_bytes"] / 1024.0 / 1024.0).round(2),
              "bytes_since_gc_mb" => (snapshot.gc_stats["bytes_since_gc"] / 1024.0 / 1024.0).round(2),
            }
          end,
          "report" => memory_report,
        },
        "benchmark" => {
          "single_result" => {
            "name"               => benchmark_result.name,
            "iterations"         => benchmark_result.iterations,
            "avg_time_ms"        => benchmark_result.avg_time.total_milliseconds.round(3),
            "min_time_ms"        => benchmark_result.min_time.total_milliseconds.round(3),
            "max_time_ms"        => benchmark_result.max_time.total_milliseconds.round(3),
            "ops_per_second"     => benchmark_result.ops_per_second.round(2),
            "memory_usage_bytes" => benchmark_result.memory_usage,
          },
          "comparison_results" => comparison_results.map do |result|
            {
              "name"           => result.name,
              "avg_time_ms"    => result.avg_time.total_milliseconds.round(3),
              "ops_per_second" => result.ops_per_second.round(2),
            }
          end,
        },
        "current_memory_usage_mb" => (Azu::PerformanceMetrics.current_memory_usage / 1024.0 / 1024.0).round(2),
      }

      GenericJsonResponse.new(data)
    end
  end
end
