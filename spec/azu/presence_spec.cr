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
        Cluster.new(Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix), Azu::Presence::Store::Redis.new(PRESENCE_REDIS_URL, prefix),
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
