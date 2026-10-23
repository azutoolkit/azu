require "./store"
require "./store/memory"

module Azu
  module Presence
    # One node of a presence cluster: it owns the metas tracked here, keeps its lease alive in the `Store`,
    # and publishes the diffs of every change through PubSub. `Azu::Presence.default` is the process-wide one.
    #
    # The lease is renewed by a fiber every *interval* (`ttl / 3` by default). `heartbeat: false` starts no fiber:
    # `sweep` does the same work on demand, which is what specs do with a fake clock.
    class Tracker
      MAX_KEY_BYTES = 256

      getter node : String
      getter ttl : Time::Span
      getter store : Store

      def initialize(@store : Store = Store::Memory.new, *, @node : String = Random::Secure.hex(6),
                     @ttl : Time::Span = 30.seconds, heartbeat : Bool = true, interval : Time::Span? = nil,
                     @pub_sub : PubSub::Backend? = nil, @max_meta_bytes : Int32 = 1024, @max_entries : Int32 = 10_000)
        @interval = heartbeat ? (interval || @ttl / 3) : nil
        @own = {} of String => Hash(String, Meta)
        @seen = {} of String => Hash(String, Meta)
        @counter = 0_i64
        @alive = false
        @mutex = Mutex.new
        @stopped = ::Channel(Nil).new
      end

      # Adds a meta for *key* to *topic* and returns it; keep its `ref` to untrack exactly this one.
      def track(topic : String, key : String, meta = nil) : Meta
        data = JSON.parse(meta.to_json)
        verify(key, data)
        ensure_alive
        entry = reserve(topic, key, data)
        arrived = !present?(topic, key)
        store.put(topic, entry)
        remember(topic, entry)
        publish(topic, Diff.new(joins: {key => [entry]}, arrived: arrived ? [key] : [] of String))
        entry
      end

      # Removes the metas *key* tracked from this node, or only *ref*. Returns what was removed.
      def untrack(topic : String, key : String, ref : String? = nil) : Array(Meta)
        removed = release(topic) { |meta| meta.key == key && (ref.nil? || meta.ref == ref) }
        removed.each { |meta| store.delete(topic, meta) }
        forget_seen(topic, removed)
        publish_leaves(topic, removed)
        removed
      end

      # The live metas of *topic* from every node, by key, oldest first.
      def list(topic : String) : Hash(String, Array(Meta))
        current = store.live(topic, Clock.now, ttl)
        publish_vanished(topic, current)
        current.group_by(&.key).transform_values(&.sort_by! { |meta| {meta.joined_at, meta.ref} })
      end

      # Delivers the diffs of *topic* (from every node) to the block.
      def subscribe(topic : String, &handler : Diff ->) : PubSub::Subscription
        pub_sub.subscribe(Presence.channel_for(topic)) do |message|
          handler.call(Diff.from_json(message.payload))
        rescue JSON::ParseException | JSON::SerializableError
          Log.for("Azu::Presence").warn { "Dropped a malformed presence diff on #{message.topic}" }
        end
      end

      # One heartbeat: renews the lease, re-asserts the metas owned here (a Redis flush or a long pause cannot
      # lose them) and publishes the leaves of metas that expired elsewhere.
      def sweep : Nil
        store.renew(node, Clock.now + ttl)
        store.prune_leases(Clock.now, ttl)
        owned.each { |topic, metas| metas.each { |meta| store.put(topic, meta) } }
        topics.each { |topic| publish_vanished(topic, store.live(topic, Clock.now, ttl)) }
      end

      # Removes everything this node tracked and stops the heartbeat.
      def shutdown : Nil
        @stopped.close unless @stopped.closed?
        owned.each_key { |topic| untrack_topic(topic) }
        store.shutdown
      end

      def pub_sub : PubSub::Backend
        @pub_sub || PubSub.backend
      end

      private def untrack_topic(topic : String) : Nil
        keys = owned[topic]?.try(&.map(&.key).uniq!) || [] of String
        keys.each { |key| untrack(topic, key) }
      rescue ex
        Log.for("Azu::Presence").warn(exception: ex) { "Could not untrack #{topic} on shutdown" }
      end

      private def verify(key : String, data : JSON::Any) : Nil
        raise LimitExceeded.new("presence key is #{key.bytesize} bytes, the limit is #{MAX_KEY_BYTES}") if key.bytesize > MAX_KEY_BYTES
        size = data.to_json.bytesize
        raise LimitExceeded.new("presence meta is #{size} bytes, the limit is #{@max_meta_bytes}") if size > @max_meta_bytes
      end

      private def reserve(topic : String, key : String, data : JSON::Any) : Meta
        @mutex.synchronize do
          entries = @own.sum(0) { |_, metas| metas.size }
          raise LimitExceeded.new("this node already tracks #{entries} presences, the limit is #{@max_entries}") if entries >= @max_entries
          @counter += 1
          Meta.new("#{node}.#{@counter}", node, key, data, Clock.now.to_unix_ms).tap do |meta|
            (@own[topic] ||= {} of String => Meta)[meta.ref] = meta
          end
        end
      end

      private def release(topic : String, & : Meta -> Bool) : Array(Meta)
        @mutex.synchronize do
          next [] of Meta unless metas = @own[topic]?
          removed = metas.values.select { |meta| yield meta }
          removed.each { |meta| metas.delete(meta.ref) }
          @own.delete(topic) if metas.empty?
          removed
        end
      end

      private def owned : Hash(String, Array(Meta))
        @mutex.synchronize { @own.transform_values(&.values) }
      end

      private def topics : Array(String)
        @mutex.synchronize { (@own.keys | @seen.keys) }
      end

      private def present?(topic : String, key : String) : Bool
        store.live(topic, Clock.now, ttl).any? { |meta| meta.key == key }
      end

      private def remember(topic : String, meta : Meta) : Nil
        @mutex.synchronize { (@seen[topic] ||= {} of String => Meta)[meta.ref] = meta }
      end

      private def forget_seen(topic : String, metas : Array(Meta)) : Nil
        @mutex.synchronize do
          next unless seen = @seen[topic]?
          metas.each { |meta| seen.delete(meta.ref) }
        end
      end

      # Publishes the leaves of what this node saw before and is gone now, then remembers *current*.
      private def publish_vanished(topic : String, current : Array(Meta)) : Nil
        refs = current.map(&.ref).to_set
        gone = @mutex.synchronize do
          previous = @seen[topic]?.try(&.values) || [] of Meta
          @seen[topic] = current.to_h { |meta| {meta.ref, meta} }
          @seen.delete(topic) if current.empty?
          previous.reject { |meta| refs.includes?(meta.ref) }
        end
        publish_leaves(topic, gone)
      end

      private def publish_leaves(topic : String, removed : Array(Meta)) : Nil
        return if removed.empty?
        remaining = store.live(topic, Clock.now, ttl).map(&.key).to_set
        leaves = removed.group_by(&.key)
        publish(topic, Diff.new(leaves: leaves, departed: leaves.keys.reject { |key| remaining.includes?(key) }))
      end

      private def publish(topic : String, diff : Diff) : Nil
        return if diff.empty?
        pub_sub.broadcast(Presence.channel_for(topic), diff.to_json)
      rescue ex
        Log.for("Azu::Presence").warn(exception: ex) { "Could not publish the presence diff of #{topic}" }
      end

      private def ensure_alive : Nil
        start = @mutex.synchronize { !@alive && (@alive = true) }
        return unless start
        store.renew(node, Clock.now + ttl)
        interval = @interval
        Azu.spawn_scoped("azu-presence") { beat(interval) } if interval
      end

      private def beat(interval : Time::Span) : Nil
        loop do
          select
          when @stopped.receive?
            break
          when timeout(interval)
            sweep_safely
          end
        end
      end

      private def sweep_safely : Nil
        sweep
      rescue ex
        Log.for("Azu::Presence").warn(exception: ex) { "Presence heartbeat failed, retrying next interval" }
      end
    end
  end
end
