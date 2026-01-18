require "../spec_helper"

describe Azu::DevelopmentTools do
  describe Azu::DevelopmentTools::Profiler do
    describe "initialization" do
      it "initializes with profiling disabled by default" do
        profiler = Azu::DevelopmentTools::Profiler.new
        profiler.enabled.should be_false
      end

      it "initializes with profiling enabled" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.enabled.should be_true
      end
    end

    describe "#enabled=" do
      it "enables profiling" do
        profiler = Azu::DevelopmentTools::Profiler.new
        profiler.enabled = true
        profiler.enabled.should be_true
      end

      it "disables profiling" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.enabled = false
        profiler.enabled.should be_false
      end
    end

    describe "#profile" do
      it "returns block result when disabled" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: false)
        result = profiler.profile("test") { 42 }
        result.should eq(42)
      end

      it "returns block result when enabled" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        result = profiler.profile("test") { 42 }
        result.should eq(42)
      end

      it "does not record entries when disabled" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: false)
        profiler.profile("test") { 42 }
        profiler.entries.size.should eq(0)
      end

      it "records entries when enabled" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("test") { 42 }
        profiler.entries.size.should eq(1)
      end

      it "records entry with correct name" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("my_operation") { 42 }
        profiler.entries.first.name.should eq("my_operation")
      end

      it "records entry with duration" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("test") { sleep 0.01.seconds }
        profiler.entries.first.duration.total_milliseconds.should be >= 10
      end

      it "records entry with memory info" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("test") { Array.new(1000) { 0 } }
        entry = profiler.entries.first
        entry.memory_before.should be >= 0
        entry.memory_after.should be >= 0
      end

      it "records entry with timestamp" do
        before = Time.utc
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("test") { 42 }
        after = Time.utc

        entry = profiler.entries.first
        entry.timestamp.should be >= before
        entry.timestamp.should be <= after
      end

      it "handles exceptions correctly" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)

        expect_raises(Exception) do
          profiler.profile("failing") { raise Exception.new("error") }
        end

        # Entry should still be recorded
        profiler.entries.size.should eq(1)
        profiler.entries.first.name.should eq("failing")
      end

      it "limits entries to prevent memory bloat" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)

        # Create more than 10000 entries
        10005.times do |i|
          profiler.profile("test_#{i}") { i }
        end

        profiler.entries.size.should eq(10000)
      end
    end

    describe "#entries" do
      it "returns empty array when no profiles recorded" do
        profiler = Azu::DevelopmentTools::Profiler.new
        profiler.entries.should be_empty
      end

      it "returns copy of entries" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("test") { 42 }

        entries1 = profiler.entries
        entries2 = profiler.entries

        entries1.should_not be(entries2)
      end
    end

    describe "#stats" do
      it "returns empty hash when no profiles recorded" do
        profiler = Azu::DevelopmentTools::Profiler.new
        profiler.stats.should be_empty
      end

      it "groups entries by name" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("operation_a") { 1 }
        profiler.profile("operation_b") { 2 }
        profiler.profile("operation_a") { 3 }

        stats = profiler.stats
        stats.keys.should contain("operation_a")
        stats.keys.should contain("operation_b")
      end

      it "calculates count correctly" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        3.times { profiler.profile("test") { 42 } }

        stats = profiler.stats["test"]
        stats["count"].should eq(3.0)
      end

      it "calculates total time" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        profiler.profile("test") { sleep 0.01.seconds }

        stats = profiler.stats["test"]
        stats["total_time_ms"].should be >= 10
      end

      it "calculates average time" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        2.times { profiler.profile("test") { sleep 0.01.seconds } }

        stats = profiler.stats["test"]
        stats["avg_time_ms"].should be >= 10
      end
    end

    describe "#clear" do
      it "clears all entries" do
        profiler = Azu::DevelopmentTools::Profiler.new(enabled: true)
        5.times { profiler.profile("test") { 42 } }

        profiler.clear
        profiler.entries.should be_empty
      end
    end
  end

  describe Azu::DevelopmentTools::Profiler::ProfileEntry do
    describe "#memory_delta" do
      it "calculates memory difference" do
        entry = Azu::DevelopmentTools::Profiler::ProfileEntry.new(
          name: "test",
          duration: 1.millisecond,
          memory_before: 1000,
          memory_after: 1500,
          timestamp: Time.utc
        )

        entry.memory_delta.should eq(500)
      end

      it "handles negative delta" do
        entry = Azu::DevelopmentTools::Profiler::ProfileEntry.new(
          name: "test",
          duration: 1.millisecond,
          memory_before: 1500,
          memory_after: 1000,
          timestamp: Time.utc
        )

        entry.memory_delta.should eq(-500)
      end
    end

    describe "#memory_delta_mb" do
      it "converts delta to megabytes" do
        entry = Azu::DevelopmentTools::Profiler::ProfileEntry.new(
          name: "test",
          duration: 1.millisecond,
          memory_before: 0,
          memory_after: 1024 * 1024, # 1 MB
          timestamp: Time.utc
        )

        entry.memory_delta_mb.should be_close(1.0, 0.001)
      end
    end
  end
end
