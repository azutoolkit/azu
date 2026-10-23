require "../spec_helper"

# Runs the block with `Instrumentation` subscribers swapped for the given ones (`nil` for none),
# so the specs behave the same whether or not `azu/dev` installed its own.
private def with_subscribers(cache : Proc(Azu::Instrumentation::CacheOperation, Nil)? = nil,
                             component : Proc(Azu::Instrumentation::ComponentEvent, Nil)? = nil, &)
  previous_cache = Azu::Instrumentation.cache_subscriber
  previous_component = Azu::Instrumentation.component_subscriber
  Azu::Instrumentation.cache_subscriber = cache
  Azu::Instrumentation.component_subscriber = component
  begin
    yield
  ensure
    Azu::Instrumentation.cache_subscriber = previous_cache
    Azu::Instrumentation.component_subscriber = previous_component
  end
end

describe Azu::Instrumentation do
  describe ".cache" do
    it "returns the block's value and reports nothing when nobody subscribed" do
      with_subscribers do
        Azu::Instrumentation.cache("k", "get", "memory") { "value" }.should eq "value"
      end
    end

    it "reports the operation with its timing, size and ttl" do
      operations = [] of Azu::Instrumentation::CacheOperation
      with_subscribers(cache: ->(op : Azu::Instrumentation::CacheOperation) { operations << op; nil }) do
        Azu::Instrumentation.cache("k", "set", "memory", 1, 5, 10.seconds) { true }.should be_true
      end

      operations.size.should eq 1
      operations.first.should eq operations.first.copy_with(key: "k", operation: "set", store: "memory", key_size: 1, value_size: 5, ttl: 10.seconds, hit: nil, error: nil)
      operations.first.duration_ms.should be >= 0.0
    end

    it "marks a get as a hit when the block returns a value and as a miss when it returns nil" do
      hits = [] of Bool?
      with_subscribers(cache: ->(op : Azu::Instrumentation::CacheOperation) { hits << op.hit; nil }) do
        Azu::Instrumentation.cache("k", "get", "memory") { "value" }
        Azu::Instrumentation.cache("k", "get", "memory") { nil }
      end
      hits.should eq [true, false]
    end

    it "reports and re-raises an error from the block" do
      errors = [] of String?
      with_subscribers(cache: ->(op : Azu::Instrumentation::CacheOperation) { errors << op.error; nil }) do
        expect_raises(Exception, "boom") { Azu::Instrumentation.cache("k", "get", "memory") { raise "boom" } }
      end
      errors.should eq ["boom"]
    end
  end

  describe ".component" do
    it "returns the block's value and reports nothing when nobody subscribed" do
      with_subscribers do
        Azu::Instrumentation.component("c1", "Counter", "mount", Time.utc) { 42 }.should eq 42
      end
    end

    it "reports the finished step" do
      events = [] of Azu::Instrumentation::ComponentEvent
      with_subscribers(component: ->(event : Azu::Instrumentation::ComponentEvent) { events << event; nil }) do
        Azu::Instrumentation.component("c1", "Counter", "refresh", 1.minute.ago) { :done }.should eq :done
      end

      events.size.should eq 1
      event = events.first
      {event.id, event.type, event.event}.should eq({"c1", "Counter", "refresh"})
      event.age.should be >= 1.minute
      event.duration_ms.should be >= 0.0
    end
  end

  describe "lifecycle hooks" do
    it "runs prepare and finalize hooks for the configuration they are called with" do
      config = Azu::Configuration.new
      seen = [] of String
      Azu::Instrumentation.on_prepare { |c| seen << "prepare" if c.same?(config) }
      Azu::Instrumentation.on_finalize { |c| seen << "finalize" if c.same?(config) }

      Azu::Instrumentation.prepare(config)
      Azu::Instrumentation.finalize(config)

      seen.should eq ["prepare", "finalize"]
    end
  end

  describe "cache manager" do
    it "reports its operations" do
      operations = [] of {String, String, Bool?}
      manager = Azu::Cache::Manager.new
      with_subscribers(cache: ->(op : Azu::Instrumentation::CacheOperation) { operations << {op.operation, op.key, op.hit}; nil }) do
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
      with_subscribers do
        manager.set("k", "v").should be_true
        manager.get("k").should eq "v"
        manager.increment("n").should eq 1
        manager.clear.should be_true
      end
    end
  end
end
