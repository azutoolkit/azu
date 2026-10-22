require "../../spec_helper"

module SparkRegistrySpec
  class Plain < Azu::Spark::Component
    def render
      span "plain"
    end
  end
end

private def entry(id : String, depth = 0) : Azu::Spark::Entry
  Azu::Spark::Entry.new(SparkRegistrySpec::Plain.new, id, nil, id, depth)
end

describe Azu::Spark::Registry do
  it "stores entries by id for its owner only" do
    mine = Azu::Spark::Registry.new("connection-a", 10)
    other = Azu::Spark::Registry.new("connection-b", 10)
    mine.add(entry("c1"))

    mine["c1"].id.should eq "c1"
    mine.owner.should eq "connection-a"
    other["c1"]?.should be_nil
    expect_raises(Azu::Spark::UnknownTarget) { other["c1"] }
  end

  it "refuses duplicates and enforces the size cap" do
    registry = Azu::Spark::Registry.new("c", 2)
    registry.add(entry("a"))

    expect_raises(Azu::Spark::BadRequest, /already in use/) { registry.add(entry("a")) }
    registry.add(entry("b"))
    expect_raises(Azu::Spark::LimitExceeded) { registry.add(entry("c")) }
    registry.size.should eq 2
  end

  it "forgets deleted entries and frees their slot" do
    registry = Azu::Spark::Registry.new("c", 1)
    registry.add(entry("a"))

    registry.delete("a").not_nil!.id.should eq "a"
    registry.delete("a").should be_nil
    registry.add(entry("b"))
    registry.size.should eq 1
  end

  it "drains everything once" do
    registry = Azu::Spark::Registry.new("c", 5)
    registry.add(entry("a"))
    registry.add(entry("b"))

    registry.drain.map(&.id).sort!.should eq ["a", "b"]
    registry.drain.should be_empty
    registry.size.should eq 0
  end

  it "is safe to use from many fibers" do
    registry = Azu::Spark::Registry.new("c", 1000)
    done = ::Channel(Nil).new

    10.times do |worker|
      spawn do
        50.times do |index|
          id = "#{worker}-#{index}"
          registry.add(entry(id))
          registry.delete(id) if index.odd?
        end
        done.send(nil)
      end
    end
    10.times { done.receive }

    registry.size.should eq 250
  end
end

describe Azu::Spark::Entry do
  it "cancels subscriptions and closes the retirement signal when retired" do
    topic_hits = 0
    entry = entry("a")
    entry.subscriptions["t"] = Azu::PubSub.subscribe("spark-entry-spec") { |_| topic_hits += 1 }

    entry.retire
    Azu::PubSub.broadcast("spark-entry-spec", "x")

    topic_hits.should eq 0
    entry.retired.closed?.should be_true
    entry.retire # idempotent
  ensure
    Azu::PubSub.shutdown
  end
end
