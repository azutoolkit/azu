require "time"
require "json"
require "http/client"
require "./performance_metrics"

module Azu
  # Development tools for performance analysis, profiling, and benchmarking
  module DevelopmentTools
    # Built-in profiler for Crystal applications
    class Profiler
      # Profile entry representing a single measurement
      struct ProfileEntry
        include JSON::Serializable

        getter name : String
        getter duration : Time::Span
        getter memory_before : Int64
        getter memory_after : Int64
        getter timestamp : Time
        getter call_stack : Array(String)?

        def initialize(@name : String, @duration : Time::Span, @memory_before : Int64,
                       @memory_after : Int64, @timestamp : Time, @call_stack : Array(String)? = nil)
        end

        def memory_delta
          @memory_after - @memory_before
        end

        def memory_delta_mb
          memory_delta / 1024.0 / 1024.0
        end
      end

      @profiles = [] of ProfileEntry
      @enabled = false
      @mutex = Mutex.new

      getter :enabled

      def initialize(@enabled = false)
      end

      # Enable/disable profiling
      def enabled=(@enabled : Bool)
      end

      # Profile a block of code
      def profile(name : String, capture_stack : Bool = false, & : -> T) : T forall T
        return yield unless @enabled

        memory_before = PerformanceMetrics.current_memory_usage
        start_time = Time.monotonic
        call_stack = capture_stack ? capture_call_stack : nil

        begin
          result = yield
        ensure
          end_time = Time.monotonic
          memory_after = PerformanceMetrics.current_memory_usage
          duration = end_time - start_time

          entry = ProfileEntry.new(
            name: name,
            duration: duration,
            memory_before: memory_before,
            memory_after: memory_after,
            timestamp: Time.utc,
            call_stack: call_stack
          )

          @mutex.synchronize do
            @profiles << entry
            # Keep only recent profiles to prevent memory bloat
            @profiles.shift if @profiles.size > 10000
          end
        end

        result
      end

      # Get all profile entries
      def entries : Array(ProfileEntry)
        @mutex.synchronize do
          @profiles.dup
        end
      end

      # Get aggregated profile statistics
      def stats : Hash(String, Hash(String, Float64))
        @mutex.synchronize do
          grouped = @profiles.group_by(&.name)
          grouped.transform_values do |entries|
            durations = entries.map(&.duration.total_milliseconds)
            memory_deltas = entries.map(&.memory_delta_mb)

            {
              "count"           => entries.size.to_f,
              "total_time_ms"   => durations.sum,
              "avg_time_ms"     => durations.sum / entries.size,
              "min_time_ms"     => durations.min,
              "max_time_ms"     => durations.max,
              "total_memory_mb" => memory_deltas.sum,
              "avg_memory_mb"   => memory_deltas.sum / entries.size,
              "max_memory_mb"   => memory_deltas.max,
            }
          end
        end
      end

      # Clear all profile data
      def clear
        @mutex.synchronize do
          @profiles.clear
        end
      end

      # Generate profile report
      def report : String
        stats_data = stats

        String.build do |str|
          str << "=== Profiler Report ===\n"
          str << "Total Profiles: #{entries.size}\n\n"

          stats_data.to_a.sort_by { |_, stats| -stats["total_time_ms"] }.each do |name, stats|
            str << "#{name}:\n"
            str << "  Count: #{stats["count"].to_i}\n"
            str << "  Total Time: #{stats["total_time_ms"].round(2)}ms\n"
            str << "  Avg Time: #{stats["avg_time_ms"].round(2)}ms\n"
            str << "  Min Time: #{stats["min_time_ms"].round(2)}ms\n"
            str << "  Max Time: #{stats["max_time_ms"].round(2)}ms\n"
            str << "  Avg Memory: #{stats["avg_memory_mb"].round(2)}MB\n"
            str << "  Max Memory: #{stats["max_memory_mb"].round(2)}MB\n\n"
          end
        end
      end

      private def capture_call_stack : Array(String)
        # Note: Crystal doesn't have built-in stack trace capture
        # This is a simplified version - in a real implementation,
        # you might use backtrace or other debugging tools
        ["<call_stack_capture_not_implemented>"]
      end
    end

    # Memory leak detection utilities
    class MemoryLeakDetector
      # Memory snapshot for comparison
      struct MemorySnapshot
        include JSON::Serializable

        getter timestamp : Time
        getter heap_size : Int64
        getter gc_stats : Hash(String, Int64)
        getter object_counts : Hash(String, Int32)?

        def initialize(@timestamp : Time, @heap_size : Int64, @gc_stats : Hash(String, Int64),
                       @object_counts : Hash(String, Int32)? = nil)
        end
      end

      # Memory leak analysis result
      struct LeakAnalysis
        include JSON::Serializable

        getter start_snapshot : MemorySnapshot
        getter end_snapshot : MemorySnapshot
        getter memory_growth : Int64
        getter memory_growth_mb : Float64
        getter duration : Time::Span
        getter suspected_leaks : Array(String)

        def initialize(@start_snapshot, @end_snapshot, @suspected_leaks = [] of String)
          @memory_growth = @end_snapshot.heap_size - @start_snapshot.heap_size
          @memory_growth_mb = @memory_growth / 1024.0 / 1024.0
          @duration = @end_snapshot.timestamp - @start_snapshot.timestamp
        end

        def leak_detected?
          @memory_growth > 10 * 1024 * 1024 # 10MB threshold
        end
      end

      @snapshots = [] of MemorySnapshot
      @monitoring = false
      @monitor_fiber : Fiber?
      @mutex = Mutex.new

      def initialize
      end

      # Start memory monitoring
      def start_monitoring(interval : Time::Span = 30.seconds)
        return if @monitoring

        @monitoring = true
        @monitor_fiber = spawn do
          while @monitoring
            take_snapshot
            sleep interval
          end
        end
      end

      # Stop memory monitoring
      def stop_monitoring
        @monitoring = false
      end

      # Take a memory snapshot
      def take_snapshot : MemorySnapshot
        gc_stats = GC.stats
        snapshot = MemorySnapshot.new(
          timestamp: Time.utc,
          heap_size: gc_stats.heap_size.to_i64,
          gc_stats: {
            "heap_size"      => gc_stats.heap_size.to_i64,
            "free_bytes"     => gc_stats.free_bytes.to_i64,
            "unmapped_bytes" => gc_stats.unmapped_bytes.to_i64,
            "bytes_since_gc" => gc_stats.bytes_since_gc.to_i64,
            "total_bytes"    => gc_stats.total_bytes.to_i64,
          }
        )

        @mutex.synchronize do
          @snapshots << snapshot
          # Keep only recent snapshots
          @snapshots.shift if @snapshots.size > 1000
        end

        snapshot
      end

      # Analyze memory usage between two snapshots
      def analyze_leak(start_snapshot : MemorySnapshot? = nil, end_snapshot : MemorySnapshot? = nil) : LeakAnalysis
        @mutex.synchronize do
          start_snap = start_snapshot || @snapshots.first?
          end_snap = end_snapshot || @snapshots.last?

          raise "Not enough snapshots for analysis" unless start_snap && end_snap

          suspected_leaks = [] of String

          # Simple heuristics for leak detection
          memory_growth = end_snap.heap_size - start_snap.heap_size
          if memory_growth > 50 * 1024 * 1024 # 50MB
            suspected_leaks << "Large memory growth detected"
          end

          # Check memory growth ratio
          total_bytes_start = start_snap.gc_stats["total_bytes"]
          total_bytes_end = end_snap.gc_stats["total_bytes"]
          bytes_since_gc_end = end_snap.gc_stats["bytes_since_gc"]

          # If we have significant growth and many bytes allocated since last GC
          if memory_growth > 10 * 1024 * 1024 && bytes_since_gc_end > 50 * 1024 * 1024 # 10MB growth, 50MB since GC
            suspected_leaks << "High memory growth with deferred GC - possible leak"
          end

          LeakAnalysis.new(start_snap, end_snap, suspected_leaks)
        end
      end

      # Get recent snapshots
      def recent_snapshots(limit : Int32 = 100) : Array(MemorySnapshot)
        @mutex.synchronize do
          @snapshots.last(limit)
        end
      end

      # Generate memory report
      def report : String
        recent = recent_snapshots(50)
        return "No memory snapshots available" if recent.empty?

        analysis = analyze_leak

        String.build do |str|
          str << "=== Memory Leak Detection Report ===\n"
          str << "Monitoring Period: #{analysis.duration.total_hours.round(2)} hours\n"
          str << "Memory Growth: #{analysis.memory_growth_mb.round(2)}MB\n"
          str << "Leak Detected: #{analysis.leak_detected? ? "YES" : "NO"}\n"

          if analysis.suspected_leaks.any?
            str << "\nSuspected Issues:\n"
            analysis.suspected_leaks.each do |issue|
              str << "- #{issue}\n"
            end
          end

          str << "\nMemory Trend (last 10 snapshots):\n"
          recent.last(10).each do |snapshot|
            str << "#{snapshot.timestamp}: #{(snapshot.heap_size / 1024.0 / 1024.0).round(2)}MB\n"
          end
        end
      end
    end

    # Performance benchmarking utilities
    class Benchmark
      # Benchmark result
      struct BenchmarkResult
        include JSON::Serializable

        getter name : String
        getter iterations : Int32
        getter total_time : Time::Span
        getter avg_time : Time::Span
        getter min_time : Time::Span
        getter max_time : Time::Span
        getter std_deviation : Float64
        getter memory_usage : Int64
        getter timestamp : Time

        def initialize(@name, @iterations, times : Array(Time::Span), @memory_usage, @timestamp)
          @total_time = times.sum
          @avg_time = @total_time / @iterations
          @min_time = times.min
          @max_time = times.max

          # Calculate standard deviation
          mean = @avg_time.total_nanoseconds
          variance = times.map { |t| (t.total_nanoseconds - mean) ** 2 }.sum / times.size
          @std_deviation = Math.sqrt(variance)
        end

        def ops_per_second
          1_000_000_000.0 / @avg_time.total_nanoseconds
        end
      end

      # Run a benchmark
      def self.run(name : String, iterations : Int32 = 1000, warmup : Int32 = 100, & : -> Nil) : BenchmarkResult
        # Warmup phase
        warmup.times { yield }

        # Force GC before measurement
        GC.collect

        memory_before = PerformanceMetrics.current_memory_usage
        times = [] of Time::Span

        # Actual benchmark
        iterations.times do
          start_time = Time.monotonic
          yield
          end_time = Time.monotonic
          times << (end_time - start_time)
        end

        memory_after = PerformanceMetrics.current_memory_usage
        memory_usage = memory_after - memory_before

        BenchmarkResult.new(name, iterations, times, memory_usage, Time.utc)
      end

      # Compare multiple benchmarks
      def self.compare(benchmarks : Hash(String, Proc(Nil)), iterations : Int32 = 1000) : Array(BenchmarkResult)
        results = [] of BenchmarkResult

        benchmarks.each do |name, block|
          result = run(name, iterations) { block.call }
          results << result
        end

        results.sort_by(&.avg_time)
      end

      # Load test an HTTP endpoint
      def self.load_test(url : String, concurrent : Int32 = 10, requests : Int32 = 1000,
                         timeout : Time::Span = 30.seconds) : Hash(String, Float64)
        channel = Channel(Time::Span).new
        errors = Channel(String).new

        start_time = Time.monotonic

        # Spawn concurrent workers
        concurrent.times do
          spawn do
            requests_per_worker = requests // concurrent
            requests_per_worker.times do
              begin
                request_start = Time.monotonic
                response = HTTP::Client.get(url, tls: false) # Disable TLS for testing
                request_end = Time.monotonic

                if response.success?
                  channel.send(request_end - request_start)
                else
                  errors.send("HTTP #{response.status_code}")
                end
              rescue ex
                errors.send(ex.message || "Unknown error")
              end
            end
          end
        end

        # Collect results
        response_times = [] of Time::Span
        error_count = 0
        total_expected = concurrent * (requests // concurrent)

        total_expected.times do
          select
          when time = channel.receive
            response_times << time
          when error = errors.receive
            error_count += 1
          when timeout(timeout)
            break
          end
        end

        end_time = Time.monotonic
        total_time = end_time - start_time

        # Calculate statistics
        response_times_ms = response_times.map(&.total_milliseconds)

        {
          "total_requests"       => response_times.size.to_f,
          "successful_requests"  => response_times.size.to_f,
          "failed_requests"      => error_count.to_f,
          "requests_per_second"  => response_times.size.to_f / total_time.total_seconds,
          "avg_response_time_ms" => response_times_ms.sum / response_times_ms.size,
          "min_response_time_ms" => response_times_ms.min? || 0.0,
          "max_response_time_ms" => response_times_ms.max? || 0.0,
          "total_time_seconds"   => total_time.total_seconds,
        }
      end
    end

    # Global instances for easy access
    @@profiler : Profiler?
    @@memory_detector : MemoryLeakDetector?

    # Get global profiler instance
    def self.profiler : Profiler
      @@profiler ||= Profiler.new
    end

    # Get global memory leak detector
    def self.memory_detector : MemoryLeakDetector
      @@memory_detector ||= MemoryLeakDetector.new
    end

    # Profile a block of code (convenience method)
    def self.profile(name : String, & : -> T) : T forall T
      profiler.profile(name) { yield }
    end

    # Enable development mode with all tools
    def self.enable_development_mode
      profiler.enabled = true
      memory_detector.start_monitoring
    end

    # Disable development mode
    def self.disable_development_mode
      profiler.enabled = false
      memory_detector.stop_monitoring
    end
  end
end
