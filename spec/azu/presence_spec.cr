require "../spec_helper"
require "../support/spark_helpers"

PRESENCE_REDIS_URL = ENV.fetch("AZU_TEST_REDIS_URL", "redis://localhost:6379/0")

private def presence_redis_available? : Bool
  redis = Redis.new(url: PRESENCE_REDIS_URL, reconnect: false)
  redis.ping
  redis.close
  true
rescue
  false
end

# Two nodes of one cluster: the store and the PubSub bus each of them talks to.
private record Cluster, store_a : Azu::Presence::Store, store_b : Azu::Presence::Store,
  bus_a : Azu::PubSub::Backend, bus_b : Azu::PubSub::Backend do
  def shutdown : Nil
    {store_a, store_b, bus_a, bus_b}.each(&.shutdown)
  end
end

private def node(store : Azu::Presence::Store, bus : Azu::PubSub::Backend, name : String) : Azu::Presence::Tracker
  Azu::Presence::Tracker.new(store, node: name, ttl: 30.seconds, heartbeat: false, pub_sub: bus)
end

private def diffs(tracker : Azu::Presence::Tracker, topic : String) : Array(Azu::Presence::Diff)
  received = [] of Azu::Presence::Diff
  tracker.subscribe(topic) { |diff| received << diff }
  received
end

# Wraps a store and, once armed, parks the next `put` until released: it forces the interleaving of a sweep
# that is writing a meta while the meta is untracked.
private class GatedStore < Azu::Presence::Store
  getter entered = ::Channel(Nil).new(1)
  getter released = ::Channel(Nil).new(1)
  property? armed = false
  property? armed_read = false

  def initialize(@inner : Azu::Presence::Store)
  end

  def put(topic : String, meta : Azu::Presence::Meta) : Nil
    if armed?
      @armed = false
      @entered.send(nil)
      @released.receive
    end
    @inner.put(topic, meta)
  end

  def delete(topic : String, meta : Azu::Presence::Meta) : Nil
    @inner.delete(topic, meta)
  end

  # Once armed, the next read returns what the store held, but only after being released: a stale read.
  def stored(topic : String) : Array(Azu::Presence::Meta)
    result = @inner.stored(topic)
    if armed_read?
      @armed_read = false
      @entered.send(nil)
      @released.receive
    end
    result
  end

  def renew(node : String, expires_at : Time) : Nil
    @inner.renew(node, expires_at)
  end

  def leases : Hash(String, Time)
    @inner.leases
  end

  def forget(nodes : Array(String)) : Nil
    @inner.forget(nodes)
  end

  def evict(topic : String, metas : Array(Azu::Presence::Meta)) : Nil
    @inner.evict(topic, metas)
  end

  def refs(topic : String) : Array(String)
    @inner.refs(topic)
  end

  def refresh(topic : String, metas : Array(Azu::Presence::Meta)) : Nil
    @inner.refresh(topic, metas)
  end

  def now : Time
    @inner.now
  end

  def present?(topic : String, key : String, now : Time, grace : Time::Span) : Bool
    @inner.present?(topic, key, now, grace)
  end
end

# Shared by every store: *make* builds a cluster of two nodes over the store under test. A Redis bus
# subscribes in its own fiber, so *settle* waits for the subscription to be live.
private def presence_examples(make : -> Cluster, settle : -> Nil = -> { })
  it "lists a tracked key with its meta and forgets it once untracked" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")

      meta = alice.track(topic, "alice", {name: "Alice"})

      alice.list(topic).keys.should eq ["alice"]
      alice.list(topic)["alice"].first.data["name"].as_s.should eq "Alice"
      alice.untrack(topic, "alice", meta.ref).map(&.ref).should eq [meta.ref]
      alice.list(topic).should be_empty
      alice.untrack(topic, "alice").should be_empty
      cluster.shutdown
    end
  end

  it "keeps one user with several metas and departs only with the last one" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      seen = diffs(alice, topic)
      settle.call

      phone = alice.track(topic, "alice", {device: "phone"})
      clock.advance(1.second)
      laptop = alice.track(topic, "alice", {device: "laptop"})
      alice.list(topic)["alice"].map(&.ref).should eq [phone.ref, laptop.ref]

      alice.untrack(topic, "alice", phone.ref)
      alice.list(topic)["alice"].map(&.ref).should eq [laptop.ref]
      alice.untrack(topic, "alice", laptop.ref)

      wait_until { seen.size == 4 }.should be_true
      seen.map(&.arrived).should eq [["alice"], [] of String, [] of String, [] of String]
      seen.map(&.departed).should eq [[] of String, [] of String, [] of String, ["alice"]]
      seen[2].leaves["alice"].map(&.ref).should eq [phone.ref]
      cluster.shutdown
    end
  end

  it "shows a node's presences to the other node and delivers its diffs there" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      seen_by_bob = diffs(bob, topic)
      settle.call

      alice.track(topic, "alice")
      bob.track(topic, "bob")

      bob.list(topic).keys.sort!.should eq ["alice", "bob"]
      alice.list(topic).keys.sort!.should eq ["alice", "bob"]
      wait_until { seen_by_bob.size == 2 }.should be_true
      seen_by_bob.flat_map(&.joins.keys).sort!.should eq ["alice", "bob"]
      cluster.shutdown
    end
  end

  it "merges the same key tracked on two nodes into one user with two metas" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      alice.track(topic, "carol")
      second = bob.track(topic, "carol")

      alice.list(topic)["carol"].map(&.node).sort!.should eq ["a", "b"]
      bob.untrack(topic, "carol", second.ref)
      alice.list(topic)["carol"].map(&.node).should eq ["a"]
      cluster.shutdown
    end
  end

  it "drops the presences of a node whose lease ran out and publishes their leaves" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      bob.track(topic, "bob")
      lost = alice.track(topic, "alice")
      seen_by_bob = diffs(bob, topic)
      settle.call
      bob.list(topic).size.should eq 2

      clock.advance(31.seconds)
      bob.sweep

      bob.list(topic).keys.should eq ["bob"]
      wait_until { seen_by_bob.size == 1 }.should be_true
      seen_by_bob.first.leaves["alice"].map(&.ref).should eq [lost.ref]
      seen_by_bob.first.departed.should eq ["alice"]
      cluster.shutdown
    end
  end

  it "keeps the presences of a node that renews its lease" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      alice.track(topic, "alice")
      bob.track(topic, "bob")

      3.times do
        clock.advance(20.seconds)
        alice.sweep
        bob.sweep
      end

      bob.list(topic).keys.sort!.should eq ["alice", "bob"]
      cluster.shutdown
    end
  end

  it "restores the metas of a node that was declared dead and came back" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      alice.track(topic, "alice")
      bob.track(topic, "bob")
      clock.advance(70.seconds)
      bob.sweep
      bob.list(topic).keys.should eq ["bob"]

      alice.sweep

      bob.list(topic).keys.sort!.should eq ["alice", "bob"]
      cluster.shutdown
    end
  end

  it "publishes the joins again when a node that was declared dead comes back" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      alice.track(topic, "alice")
      seen = diffs(bob, topic)
      settle.call

      clock.advance(31.seconds)
      bob.sweep
      wait_until { seen.size == 1 }.should be_true
      seen.last.departed.should eq ["alice"]

      alice.sweep
      bob.sweep

      wait_until { seen.size == 2 }.should be_true
      seen.last.arrived.should eq ["alice"]
      seen.last.joins["alice"].size.should eq 1
      cluster.shutdown
    end
  end

  it "publishes the leaves of a node whose joins no watcher heard" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      deaf_bus = Azu::PubSub::Memory.new
      alice = node(cluster.store_a, deaf_bus, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      seen = diffs(bob, topic)
      settle.call

      alice.track(topic, "alice")
      bob.sweep
      wait_until { seen.size == 1 }.should be_true
      seen.first.arrived.should eq ["alice"]

      clock.advance(31.seconds)
      bob.sweep

      wait_until { seen.size == 2 }.should be_true
      seen.last.departed.should eq ["alice"]
      cluster.shutdown
    end
  end

  it "does not put a meta back that was untracked while the sweep was writing it" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      gated = GatedStore.new(cluster.store_a)
      alice = node(gated, cluster.bus_a, "a")
      lost = alice.track(topic, "alice")
      cluster.store_a.evict(topic, [lost]) # a flush: the sweep has a meta to put back
      gated.armed = true
      done = ::Channel(Nil).new

      spawn { alice.sweep; done.send(nil) }
      gated.entered.receive
      spawn { alice.untrack(topic, "alice"); done.send(nil) }
      sleep 20.milliseconds
      gated.released.send(nil)
      2.times { done.receive }

      alice.list(topic).should be_empty
      gated.stored(topic).should be_empty
      cluster.shutdown
    end
  end

  it "replaces a meta without the key departing and arriving again" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      old = alice.track(topic, "alice", {status: "online"})
      seen = diffs(alice, topic)
      settle.call

      fresh = alice.update(topic, "alice", old.ref, {status: "away"})
      fresh.should_not be_nil
      fresh = fresh.as(Azu::Presence::Meta)

      alice.list(topic)["alice"].map(&.ref).should eq [fresh.ref]
      alice.list(topic)["alice"].first.data["status"].as_s.should eq "away"
      wait_until { seen.size == 2 }.should be_true
      seen.flat_map(&.arrived).should be_empty
      seen.flat_map(&.departed).should be_empty
      alice.update(topic, "alice", old.ref).should be_nil
      cluster.shutdown
    end
  end

  it "numbers the diffs of a node and does not publish from list" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do |clock|
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(cluster.store_b, cluster.bus_b, "b")
      seen = diffs(bob, topic)
      settle.call

      alice.track(topic, "alice")
      alice.track(topic, "alice")
      wait_until { seen.size == 2 }.should be_true
      seen.map(&.node).should eq ["a", "a"]
      seen.map(&.seq).should eq [1_i64, 2_i64]

      clock.advance(31.seconds)
      bob.list(topic)
      sleep 50.milliseconds
      seen.size.should eq 2
      cluster.shutdown
    end
  end

  it "reports a key as arrived once when fibers track it at the same time" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      seen = diffs(alice, topic)
      settle.call
      done = ::Channel(Nil).new
      8.times { spawn { alice.track(topic, "carol"); done.send(nil) } }
      8.times { done.receive }

      wait_until { seen.size == 8 }.should be_true
      seen.flat_map(&.arrived).should eq ["carol"]
      cluster.shutdown
    end
  end

  it "tells keys apart that only differ by glob characters" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      seen = diffs(alice, topic)
      settle.call

      alice.track(topic, "a*")
      alice.track(topic, "ab")
      alice.track(topic, "a[b]")

      wait_until { seen.size == 3 }.should be_true
      seen.flat_map(&.arrived).sort!.should eq ["a*", "a[b]", "ab"]
      cluster.shutdown
    end
  end

  it "bounds the length of a topic" do
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      expect_raises(Azu::Presence::LimitExceeded, /topic/) { alice.track("t" * 300, "alice") }
      expect_raises(Azu::Presence::LimitExceeded, /topic/) { alice.list("t" * 300) }
      cluster.shutdown
    end
  end

  it "keeps delivering diffs to a subscriber after its handler raised" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      received = [] of String
      alice.subscribe(topic) do |diff|
        received << diff.joins.keys.first
        raise "handler failed" if received.size == 1
      end
      settle.call

      alice.track(topic, "one")
      alice.track(topic, "two")

      wait_until { received.size == 2 }.should be_true
      received.should eq ["one", "two"]
      cluster.shutdown
    end
  end

  it "does not read the topic to tell whether a key is present" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      200.times { |index| alice.track(topic, "user-#{index}") }
      alice.track(topic, "special")

      cluster.store_b.present?(topic, "special", cluster.store_b.now, 30.seconds).should be_true
      cluster.store_b.present?(topic, "spec", cluster.store_b.now, 30.seconds).should be_false
      cluster.store_b.present?(topic, "user-199", cluster.store_b.now, 30.seconds).should be_true
      cluster.shutdown
    end
  end

  it "stops following a topic once every watch and subscription on it is cancelled" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      received = [] of Azu::Presence::Diff
      subscription = alice.subscribe(topic) { |diff| received << diff }
      extra = alice.watch(topic)
      settle.call

      subscription.cancel
      alice.track(topic, "alice") # still watched through *extra*
      wait_until { alice.watching?(topic) }.should be_true
      extra.cancel
      extra.cancel

      alice.watching?(topic).should be_false
      received.should be_empty
      cluster.shutdown
    end
  end

  it "does not publish a join again that the node announced itself" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      seen = diffs(alice, topic)
      settle.call

      alice.track(topic, "alice")
      alice.sweep
      alice.untrack(topic, "alice")
      alice.sweep

      wait_until { seen.size == 2 }.should be_true
      sleep 50.milliseconds
      seen.size.should eq 2
      cluster.shutdown
    end
  end

  it "does not announce a meta as a join when its leave arrived while the store was being read" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      gated = GatedStore.new(cluster.store_b)
      alice = node(cluster.store_a, cluster.bus_a, "a")
      bob = node(gated, cluster.bus_b, "b")
      gone = alice.track(topic, "alice")
      seen = diffs(bob, topic)
      settle.call
      done = ::Channel(Nil).new

      gated.armed_read = true
      spawn { bob.sweep; done.send(nil) }
      gated.entered.receive # bob read a store that still holds alice
      alice.untrack(topic, "alice", gone.ref)
      wait_until { seen.size == 1 }.should be_true
      gated.released.send(nil)
      done.receive

      sleep 50.milliseconds
      seen.size.should eq 1
      seen.first.departed.should eq ["alice"]
      cluster.shutdown
    end
  end

  it "keeps a stale Watch from taking a count that belongs to a later watcher" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      stale = alice.watch(topic)
      alice.unwatch(topic)
      fresh = alice.watch(topic)

      stale.cancel

      alice.watching?(topic).should be_true
      fresh.cancel
      alice.watching?(topic).should be_false
      cluster.shutdown
    end
  end

  it "bounds the size of keys, metas and the metas one node tracks" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      small = Azu::Presence::Tracker.new(cluster.store_a, node: "s", heartbeat: false, pub_sub: cluster.bus_a, max_meta_bytes: 32, max_entries: 2)

      expect_raises(Azu::Presence::LimitExceeded, /meta is/) { small.track(topic, "k", {note: "x" * 64}) }
      expect_raises(Azu::Presence::LimitExceeded, /key is/) { small.track(topic, "k" * 300) }
      small.track(topic, "one")
      small.track(topic, "two")
      expect_raises(Azu::Presence::LimitExceeded, /limit is 2/) { small.track(topic, "three") }
      small.list(topic).keys.sort!.should eq ["one", "two"]
      cluster.shutdown
    end
  end

  it "stays consistent when fibers track and untrack concurrently" do
    topic = "room:#{Random::Secure.hex(4)}"
    with_fake_clock do
      cluster = make.call
      alice = node(cluster.store_a, cluster.bus_a, "a")
      done = ::Channel(Nil).new
      20.times do |index|
        spawn do
          meta = alice.track(topic, "user-#{index % 4}")
          alice.untrack(topic, meta.key, meta.ref) if index.odd?
          done.send(nil)
        end
      end
      20.times { done.receive }

      alice.list(topic).values.sum(&.size).should eq 10
      cluster.shutdown
    end
  end
end

describe Azu::Presence do
  describe Azu::Presence::Store::Memory do
    presence_examples(-> {
      store = Azu::Presence::Store::Memory.new
      bus = Azu::PubSub::Memory.new
      Cluster.new(store, store, bus, bus)
    })
  end

  describe Azu::Presence::Store::Redis do
    prefix = "azu:test:presence:#{Random::Secure.hex(4)}:"
    after_all do
      next unless presence_redis_available?
      redis = Redis.new(url: PRESENCE_REDIS_URL, reconnect: false)
      redis.keys("#{prefix}*").each { |key| redis.del(key.as(String)) }
      redis.close
    end
    presence_examples(
      -> {
        pending!("Redis is not reachable on #{PRESENCE_REDIS_URL}") unless presence_redis_available?
        bus_prefix = "#{prefix}bus:"
        Cluster.new(Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix, server_time: false), Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix, server_time: false),
          Azu::PubSub::Redis.new(PRESENCE_REDIS_URL, bus_prefix), Azu::PubSub::Redis.new(PRESENCE_REDIS_URL, bus_prefix))
      },
      -> { sleep 200.milliseconds }
    )
  end
end

class LobbyChannel < Azu::Channel
  include Azu::Presence::Tracked

  def on_connect
    presence_updates("lobby")
    track_presence("lobby", params["user"], {"device" => params["device"]?})
  end

  def on_message(message : String)
    raise "boom" if message == "crash"
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end

describe Azu::Presence::Tracked do
  before_each { Azu::Presence.default = Azu::Presence::Tracker.new(heartbeat: false) }
  after_each do
    Azu::Presence.shutdown
    Azu::PubSub.shutdown
  end

  it "untracks a socket when it closes and keeps the user while another device is connected" do
    with_ws_server(Azu::Channel::Upgrader.new(LobbyChannel)) do |port|
      watcher = WsProbe.new(port, "/?user=bob")
      phone = WsProbe.new(port, "/?user=alice&device=phone")
      laptop = WsProbe.new(port, "/?user=alice&device=laptop")
      wait_until { Azu::Presence.list("lobby")["alice"]?.try(&.size) == 2 }.should be_true

      phone.close
      wait_until { Azu::Presence.list("lobby")["alice"]?.try(&.size) == 1 }.should be_true
      Azu::Presence.list("lobby")["alice"].first.data["device"].as_s.should eq "laptop"
      laptop.close
      wait_until { !Azu::Presence.list("lobby").has_key?("alice") }.should be_true

      diffs = [] of Azu::Presence::Diff
      while frame = watcher.receive(300.milliseconds)
        diffs << Azu::Presence::Diff.from_json(frame)
      end
      diffs.flat_map(&.arrived).should eq ["bob", "alice"]
      diffs.flat_map(&.departed).should eq ["alice"]
      watcher.close
    end
  end

  it "untracks a socket whose handler raised" do
    with_ws_server(Azu::Channel::Upgrader.new(LobbyChannel)) do |port|
      client = WsProbe.new(port, "/?user=carol")
      wait_until { Azu::Presence.list("lobby").has_key?("carol") }.should be_true

      client.send("crash")

      wait_until { !Azu::Presence.list("lobby").has_key?("carol") }.should be_true
    end
  end
end

describe Azu::Presence::Tracker do
  it "renews its lease from a heartbeat fiber, so only a silent node expires" do
    store = Azu::Presence::Store::Memory.new
    bus = Azu::PubSub::Memory.new
    beating = Azu::Presence::Tracker.new(store, node: "beating", ttl: 300.milliseconds, interval: 50.milliseconds, pub_sub: bus)
    silent = Azu::Presence::Tracker.new(store, node: "silent", ttl: 300.milliseconds, heartbeat: false, pub_sub: bus)
    beating.track("t", "alive")
    silent.track("t", "dead")

    wait_until { !beating.list("t").has_key?("dead") }.should be_true

    beating.list("t").keys.should eq ["alive"]
    wait_until { beating.list("t"); store.stored("t").map(&.key) == ["alive"] }.should be_true
    beating.shutdown
    store.stored("t").should be_empty
  end

  it "restarts the heartbeat when a tracker that was shut down tracks again" do
    store = Azu::Presence::Store::Memory.new
    bus = Azu::PubSub::Memory.new
    first = Azu::Presence::Tracker.new(store, node: "first", ttl: 300.milliseconds, interval: 50.milliseconds, pub_sub: bus)
    observer = Azu::Presence::Tracker.new(store, node: "observer", ttl: 300.milliseconds, heartbeat: false, pub_sub: bus)
    first.track("t", "before")
    first.shutdown

    first.track("t", "after")
    sleep 700.milliseconds

    observer.list("t").keys.should eq ["after"]
    first.shutdown
  end

  it "is stopped by Azu.shutdown, which removes the entries of the default tracker" do
    store = Azu::Presence::Store::Memory.new
    Azu::Presence.default = Azu::Presence::Tracker.new(store, heartbeat: false, pub_sub: Azu::PubSub::Memory.new)
    Azu::Presence.track("t", "alice")

    Azu.shutdown

    store.stored("t").should be_empty
  end

  it "judges leases by the Redis clock unless told to follow Azu::Clock" do
    pending!("Redis is not reachable on #{PRESENCE_REDIS_URL}") unless presence_redis_available?
    prefix = "azu:test:presence:time:#{Random::Secure.hex(4)}:"
    store = Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix)
    fake = Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix, server_time: false)

    with_fake_clock do |clock|
      clock.advance(1.day)
      (store.now - Time.utc).abs.should be < 5.seconds
      (fake.now - Time.utc).should be > 20.hours
    end
    store.shutdown
    fake.shutdown
  end

  it "refuses to let a channel subscribe to or broadcast on a presence topic" do
    channel = LobbyChannel.new(HTTP::WebSocket.new(IO::Memory.new))

    expect_raises(ArgumentError, /reserved/) { channel.subscribe("presence:lobby") }
    expect_raises(ArgumentError, /reserved/) { channel.broadcast("presence:lobby", "{}") }
    channel.subscribe("lobby")
    channel.teardown
  end

  it "repairs a key index that lost an entry of an owned meta on the next sweep" do
    pending!("Redis is not reachable on #{PRESENCE_REDIS_URL}") unless presence_redis_available?
    prefix = "azu:test:presence:index:#{Random::Secure.hex(4)}:"
    store = Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix, server_time: false)
    alice = Azu::Presence::Tracker.new(store, node: "a", heartbeat: false, pub_sub: Azu::PubSub::Memory.new)
    meta = alice.track("room", "alice")
    redis = Redis.new(url: PRESENCE_REDIS_URL, reconnect: false)
    begin
      redis.hdel("#{prefix}k:room\u001falice", meta.ref)
      store.present?("room", "alice", store.now, 30.seconds).should be_false

      alice.sweep

      store.present?("room", "alice", store.now, 30.seconds).should be_true
      alice.untrack("room", "alice", meta.ref)
      alice.sweep
      store.stored("room").should be_empty
      store.present?("room", "alice", store.now, 30.seconds).should be_false
    ensure
      redis.keys("#{prefix}*").each { |key| redis.del(key.as(String)) }
      redis.close
      store.shutdown
    end
  end

  it "does not leak a watch or a presence when a channel is torn down before it asks for them" do
    channel = LobbyChannel.new(HTTP::WebSocket.new(IO::Memory.new))
    channel.teardown

    channel.presence_updates("lobby")
    channel.track_presence("lobby", "late")

    Azu::Presence.default.watching?("lobby").should be_false
    Azu::Presence.list("lobby").should be_empty
  end

  it "delegates the module API to the default tracker" do
    Azu::Presence.default = Azu::Presence::Tracker.new(heartbeat: false, pub_sub: Azu::PubSub::Memory.new)
    received = [] of Azu::Presence::Diff
    subscription = Azu::Presence.subscribe("api") { |diff| received << diff }

    meta = Azu::Presence.track("api", "dave", {"role" => "admin"})

    Azu::Presence.list("api")["dave"].first.should eq meta
    received.first.joins["dave"].first.should eq meta
    Azu::Presence.untrack("api", "dave").size.should eq 1
    received.size.should eq 2
    subscription.cancel
    Azu::Presence.shutdown
  end
end
