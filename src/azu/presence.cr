require "json"
require "log"
require "./pub_sub"
require "./presence/*"
require "./presence/store/*"

module Azu
  # Who is in a topic, across processes: `track` a key (a user id, a session) with some metadata,
  # `list` the topic, and subscribe to the join/leave diffs that every change publishes through
  # `Azu::PubSub` on `presence:<topic>`.
  #
  # ```
  # meta = Azu::Presence.track("room:1", "alice", {name: "Alice"})
  # Azu::Presence.list("room:1").keys # => ["alice"]
  # Azu::Presence.subscribe("room:1") { |diff| puts diff.joins.keys }
  # Azu::Presence.untrack("room:1", "alice", meta.ref)
  # ```
  #
  # ## Guarantees
  #
  # * A *key* is a user; every `track` call adds one `Meta` to it (one per device, socket or tab). The key is
  #   listed while at least one of its metas is alive on any node, and it only `departed` when the last goes.
  # * Each node owns the metas it tracked, named `<node>.<counter>` with a per-node monotonic counter. Only the
  #   owner adds or removes them, so the state of a topic is the union of per-node sets that never conflict:
  #   merging is commutative, idempotent and needs no coordination (a CRDT-lite grow/remove set per node).
  # * A node renews a lease every `ttl / 3` and re-asserts its metas with it. Once a lease is a `ttl` old
  #   (crash, SIGKILL, partition), `list` stops returning that node's metas, and the next sweep or `list` on a
  #   surviving node publishes their `leaves`.
  # * Diffs are at-most-once hints and may repeat: apply them by `ref` (idempotent), and `list` is the truth,
  #   so re-list after a reconnect. `arrived` and `departed` are decided by the tracking node from what it
  #   saw, so two nodes tracking the same new key in the same instant may both report it `arrived`.
  # * Expiry compares wall-clock times written by different nodes (`Azu::Clock.now`): keep node clocks within
  #   a fraction of the `ttl`.
  module Presence
    class LimitExceeded < ArgumentError
    end

    @@default : Tracker? = nil
    @@mutex = Mutex.new

    # The process-wide tracker, backed by `Store::Memory` until `default=` installs another one.
    def self.default : Tracker
      @@mutex.synchronize { @@default ||= Tracker.new }
    end

    # Replaces the tracker, shutting the previous one down.
    def self.default=(tracker : Tracker) : Tracker
      previous = @@mutex.synchronize { @@default.tap { @@default = tracker } }
      previous.try(&.shutdown)
      tracker
    end

    # Stops the default tracker and forgets it; the next use starts a fresh in-memory one.
    def self.shutdown : Nil
      previous = @@mutex.synchronize { @@default.tap { @@default = nil } }
      previous.try(&.shutdown)
    end

    # The PubSub topic that carries the diffs of *topic*.
    def self.channel_for(topic : String) : String
      "presence:#{topic}"
    end

    def self.track(topic : String, key : String, meta = nil) : Meta
      default.track(topic, key, meta)
    end

    def self.untrack(topic : String, key : String, ref : String? = nil) : Array(Meta)
      default.untrack(topic, key, ref)
    end

    def self.list(topic : String) : Hash(String, Array(Meta))
      default.list(topic)
    end

    def self.subscribe(topic : String, &handler : Diff ->) : PubSub::Subscription
      default.subscribe(topic, &handler)
    end
  end
end
