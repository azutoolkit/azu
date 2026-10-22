require "../spec_helper"

REDIS_URL = ENV.fetch("AZU_TEST_REDIS_URL", "redis://localhost:6379/0")

# Patterns currently subscribed on the server: the Redis backend's listener subscribes in its own
# fiber, so a spec has to wait for this to grow before it publishes.
private def redis_pattern_count : Int64
  redis = Redis.new(url: REDIS_URL, reconnect: false)
  begin
    redis.command(["PUBSUB", "NUMPAT"]).as(Int64)
  ensure
    redis.close
  end
end

private def wait_for_listener(baseline : Int64) : Nil
  wait_until { redis_pattern_count > baseline }.should be_true
end

private def redis_available? : Bool
  redis = Redis.new(url: REDIS_URL, reconnect: false)
  redis.ping
  redis.close
  true
rescue
  false
end

private def collect(backend : Azu::PubSub::Backend, topic : String) : {Array(String), Azu::PubSub::Subscription}
  received = [] of String
  subscription = backend.subscribe(topic) { |message| received << message.payload }
  {received, subscription}
end

describe Azu::PubSub do
  describe Azu::PubSub::Memory do
    it "delivers broadcasts to subscribers of the topic only" do
      backend = Azu::PubSub::Memory.new
      received, _ = collect(backend, "news")
      other, _ = collect(backend, "sports")

      backend.broadcast("news", "hello")

      received.should eq ["hello"]
      other.should be_empty
    end

    it "delivers in subscription order to every subscriber" do
      backend = Azu::PubSub::Memory.new
      order = [] of Int32
      3.times { |index| backend.subscribe("t") { |_| order << index } }

      backend.broadcast("t", "x")

      order.should eq [0, 1, 2]
    end

    it "stops delivering after cancel and cancel is idempotent" do
      backend = Azu::PubSub::Memory.new
      received, subscription = collect(backend, "news")

      subscription.cancel
      subscription.cancel
      backend.broadcast("news", "late")

      received.should be_empty
      subscription.cancelled?.should be_true
      backend.subscriber_count.should eq 0
    end

    it "does not deliver to a subscription cancelled by an earlier handler of the same broadcast" do
      backend = Azu::PubSub::Memory.new
      received = [] of String
      second = nil.as(Azu::PubSub::Subscription?)
      backend.subscribe("t") { |_| second.try(&.cancel) }
      second = backend.subscribe("t") { |message| received << message.payload }

      backend.broadcast("t", "x")

      received.should be_empty
    end

    it "isolates a failing subscriber from the others" do
      backend = Azu::PubSub::Memory.new
      received, _ = collect(backend, "t")
      backend.subscribe("t") { |_| raise "boom" }

      backend.broadcast("t", "x")

      received.should eq ["x"]
    end

    it "is safe to use from many fibers" do
      backend = Azu::PubSub::Memory.new
      count = Atomic(Int32).new(0)
      done = ::Channel(Nil).new

      20.times do
        spawn do
          50.times do
            subscription = backend.subscribe("t") { |_| count.add(1) }
            backend.broadcast("t", "x")
            subscription.cancel
          end
          done.send(nil)
        end
      end
      20.times { done.receive }

      backend.subscriber_count.should eq 0
      count.get.should be >= 20 * 50
    end

    it "forgets every subscription on shutdown" do
      backend = Azu::PubSub::Memory.new
      received, _ = collect(backend, "t")

      backend.shutdown
      backend.broadcast("t", "x")

      received.should be_empty
    end
  end

  describe "module API" do
    after_each { Azu::PubSub.shutdown }

    it "uses an in-memory backend by default" do
      Azu::PubSub.backend.should be_a(Azu::PubSub::Memory)
    end

    it "broadcasts strings and JSON encodable data" do
      messages = [] of Azu::PubSub::Message
      Azu::PubSub.subscribe("todos") { |message| messages << message }

      Azu::PubSub.broadcast("todos", "plain")
      Azu::PubSub.broadcast("todos", {id: 1})

      messages.map(&.payload).should eq ["plain", %({"id":1})]
      messages.last.topic.should eq "todos"
      messages.last.json(NamedTuple(id: Int32)).should eq({id: 1})
    end

    it "shuts the previous backend down when it is replaced" do
      received = [] of String
      Azu::PubSub.subscribe("t") { |message| received << message.payload }

      Azu::PubSub.backend = Azu::PubSub::Memory.new
      Azu::PubSub.broadcast("t", "x")

      received.should be_empty
    end
  end

  describe Azu::PubSub::Redis do
    it "fans broadcasts out across backend instances" do
      pending!("Redis is not reachable on localhost:6379") unless redis_available?

      prefix = "azu:test:#{Random::Secure.hex(4)}:"
      node_a = Azu::PubSub::Redis.new(REDIS_URL, prefix)
      node_b = Azu::PubSub::Redis.new(REDIS_URL, prefix)
      inbox = ::Channel(String).new(4)
      baseline = redis_pattern_count
      node_a.subscribe("room:1") { |message| inbox.send("#{message.topic}=#{message.payload}") }
      wait_for_listener(baseline)

      node_b.broadcast("room:1", "hi")
      node_b.broadcast("room:2", "ignored")

      select
      when delivered = inbox.receive
        delivered.should eq "room:1=hi"
      when timeout(3.seconds)
        fail "no message reached the subscriber through Redis"
      end
    ensure
      node_a.try(&.shutdown)
      node_b.try(&.shutdown)
    end

    it "publishes again after its publisher connection is dropped" do
      pending!("Redis is not reachable on #{REDIS_URL}") unless redis_available?

      prefix = "azu:test:#{Random::Secure.hex(4)}:"
      node_a = Azu::PubSub::Redis.new(REDIS_URL, prefix)
      node_b = Azu::PubSub::Redis.new(REDIS_URL, prefix)
      inbox = ::Channel(String).new(4)
      baseline = redis_pattern_count
      node_a.subscribe("room") { |message| inbox.send(message.payload) }
      wait_for_listener(baseline)

      node_b.broadcast("room", "first")
      inbox.receive.should eq "first"

      # node_b's publisher is the only client whose last command was PUBLISH.
      admin = Redis.new(url: REDIS_URL, reconnect: false)
      listing = admin.command(["CLIENT", "LIST"]).as(String)
      ids = listing.lines.select(&.includes?("cmd=publish")).compact_map(&.match(/\bid=(\d+)/).try(&.[1]))
      ids.should_not be_empty
      ids.each { |id| admin.command(["CLIENT", "KILL", "ID", id]) }
      admin.close

      node_b.broadcast("room", "second")
      select
      when delivered = inbox.receive
        delivered.should eq "second"
      when timeout(3.seconds)
        fail "broadcast after the publisher connection dropped never arrived"
      end
    ensure
      node_a.try(&.shutdown)
      node_b.try(&.shutdown)
    end

    it "stops its listener fiber and rejects further work on shutdown" do
      pending!("Redis is not reachable on localhost:6379") unless redis_available?

      backend = Azu::PubSub::Redis.new(REDIS_URL, prefix: "azu:test:#{Random::Secure.hex(4)}:")
      baseline = redis_pattern_count
      subscription = backend.subscribe("t") { |_| }
      wait_for_listener(baseline)

      backend.shutdown
      backend.shutdown # idempotent
      subscription.cancel
    end
  end
end
