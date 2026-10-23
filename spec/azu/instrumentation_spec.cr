require "../spec_helper"

describe Azu::Instrumentation do
  describe ".cache" do
    it "returns the block's value and reports nothing when nobody subscribed" do
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.cache("k", "get", "memory") { "value" }.should eq "value"
      end
    end

    it "reports the operation with its timing, size and ttl" do
      operations = [] of Azu::Instrumentation::CacheOperation
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache { |op| operations << op }
        Azu::Instrumentation.cache("k", "set", "memory", 1, 5, 10.seconds) { true }.should be_true
      end

      operations.size.should eq 1
      operations.first.should eq operations.first.copy_with(key: "k", operation: "set", store: "memory", key_size: 1, value_size: 5, ttl: 10.seconds, hit: nil, error: nil)
      operations.first.duration_ms.should be >= 0.0
    end

    it "marks a get as a hit when the block returns a value and as a miss when it returns nil" do
      hits = [] of Bool?
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache { |op| hits << op.hit }
        Azu::Instrumentation.cache("k", "get", "memory") { "value" }
        Azu::Instrumentation.cache("k", "get", "memory") { nil }
      end
      hits.should eq [true, false]
    end

    it "reports and re-raises an error from the block" do
      errors = [] of String?
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache { |op| errors << op.error }
        expect_raises(Exception, "boom") { Azu::Instrumentation.cache("k", "get", "memory") { raise "boom" } }
      end
      errors.should eq ["boom"]
    end
  end

  describe ".component" do
    it "returns the block's value and reports nothing when nobody subscribed" do
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.component("c1", "Counter", "mount", Time.utc) { 42 }.should eq 42
      end
    end

    it "reports the finished step" do
      events = [] of Azu::Instrumentation::ComponentEvent
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_component { |event| events << event }
        Azu::Instrumentation.component("c1", "Counter", "refresh", 1.minute.ago) { :done }.should eq :done
      end

      events.size.should eq 1
      event = events.first
      {event.id, event.type, event.event}.should eq({"c1", "Counter", "refresh"})
      event.age.should be >= 1.minute
      event.duration_ms.should be >= 0.0
    end
  end

  describe "subscribers" do
    it "notifies every subscriber, so integrations do not replace each other" do
      calls = [] of String
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache { |_| calls << "apm" }
        Azu::Instrumentation.on_cache { |_| calls << "dev" }
        Azu::Instrumentation.cache("k", "get", "memory") { nil }
      end
      calls.should eq ["apm", "dev"]
    end

    it "does not time or report while a subscriber says it is disabled" do
      called = false
      asked = 0
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache(-> { asked += 1; false }) { |_| called = true }
        Azu::Instrumentation.on_component(-> { false }) { |_| called = true }
        Azu::Instrumentation.cache("k", "get", "memory") { "v" }.should eq "v"
        Azu::Instrumentation.component("c", "T", "mount", Time.utc) { 1 }.should eq 1
      end
      called.should be_false
      asked.should be > 0
    end

    it "keeps the operation and its own exception when a subscriber raises" do
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache(-> { raise "enabled broke" }) { |_| }
        Azu::Instrumentation.on_cache { |_| raise "subscriber broke" }
        Azu::Instrumentation.on_component { |_| raise "subscriber broke" }

        Azu::Instrumentation.cache("k", "get", "memory") { "v" }.should eq "v"
        Azu::Instrumentation.component("c", "T", "mount", Time.utc) { 2 }.should eq 2
        expect_raises(Exception, "store failed") { Azu::Instrumentation.cache("k", "get", "memory") { raise "store failed" } }
      end
    end
  end

  describe "lifecycle hooks" do
    it "runs prepare and finalize hooks for the configuration they are called with" do
      config = Azu::Configuration.new
      seen = [] of String
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_prepare { |c| seen << "prepare" if c.same?(config) }
        Azu::Instrumentation.on_finalize { |c| seen << "finalize" if c.same?(config) }

        Azu::Instrumentation.prepare(config)
        Azu::Instrumentation.finalize(config)
      end

      seen.should eq ["prepare", "finalize"]
    end

    it "runs the remaining hooks when one raises" do
      config = Azu::Configuration.new
      ran = [] of String
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_prepare { |_| raise "bad hook" }
        Azu::Instrumentation.on_prepare { |_| ran << "second" }
        Azu::Instrumentation.on_finalize { |_| raise "bad hook" }
        Azu::Instrumentation.on_finalize { |_| ran << "last" }

        Azu::Instrumentation.prepare(config)
        Azu::Instrumentation.finalize(config)
      end

      ran.should eq ["second", "last"]
    end
  end

  describe "cache manager" do
    it "reports its operations" do
      operations = [] of {String, String, Bool?}
      manager = Azu::Cache::Manager.new
      Azu::Instrumentation.isolate do
        Azu::Instrumentation.on_cache { |op| operations << {op.operation, op.key, op.hit} }
        manager.fetch("answer") { "42" }.should eq "42"
        manager.fetch("answer") { "unused" }.should eq "42"
        manager.exists?("answer")
        manager.delete("answer")
      end

      operations.should eq [
        {"get", "answer", false}, {"set", "answer", nil},
        {"get", "answer", true},
        {"exists", "answer", nil}, {"delete", "answer", nil},
      ]
    end

    it "works without any subscriber" do
      manager = Azu::Cache::Manager.new
      Azu::Instrumentation.isolate do
        manager.set("k", "v").should be_true
        manager.get("k").should eq "v"
        manager.increment("n").should eq 1
        manager.clear.should be_true
      end
    end
  end
end
