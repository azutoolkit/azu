require "./store"
require "./store/memory"

module Azu
  module Presence
    # One node of a presence cluster: it owns the metas tracked here, keeps its lease alive in the `Store`, and
    # publishes the diffs of every change through PubSub. `Azu::Presence.default` is the process-wide one.
    #
    # The lease is renewed by a fiber every *interval* (`ttl / 3` by default). `heartbeat: false` starts no fiber:
    # `sweep` does the same work on demand, which is what specs do with a fake clock.
    #
    # A node that *watches* a topic (`subscribe` and `watch` do) remembers what it last saw there and, on every
    # sweep, publishes the difference to what the store holds: the leaves of expired nodes, and the joins of
    # metas it never heard about (a node that came back after a pause, a diff that was lost).
    class Tracker
      MAX_KEY_BYTES   = 256
      MAX_TOPIC_BYTES = 256
      STRIPES         =  64

      getter node : String
      getter ttl : Time::Span
      getter store : Store

      def initialize(@store : Store = Store::Memory.new, *, @node : String = Random::Secure.hex(6),
                     @ttl : Time::Span = 30.seconds, heartbeat : Bool = true, interval : Time::Span? = nil,
                     @pub_sub : PubSub::Backend? = nil, @max_meta_bytes : Int32 = 1024, @max_entries : Int32 = 10_000)
        @interval = heartbeat ? (interval || @ttl / 3) : nil
        @own = {} of String => Hash(String, Meta)
        @seen = {} of String => Hash(String, Meta)
        @watchers = {} of String => Int32
        @tokens = {} of String => Int64
        @watching = {} of String => PubSub::Subscription
        @epoch = 0_i64
        @reading = {} of String => Set(String)
        @counter = 0_i64
        @sequence = 0_i64
        @alive = false
        @mutex = Mutex.new
        @locks = Array(Mutex).new(STRIPES) { Mutex.new }
        @stopped = ::Channel(Nil).new
      end

      # Adds a meta for *key* to *topic* and returns it; keep its `ref` to untrack exactly this one.
      def track(topic : String, key : String, meta = nil) : Meta
        data = JSON.parse(meta.to_json)
        verify(topic, key, data)
        ensure_alive
        now = store.now
        entry, arrived = with_key(key) do
          present = store.present?(topic, key, now, ttl)
          reserved = reserve(topic, key, data, now)
          put_or_release(topic, reserved)
          {reserved, !present}
        end
        emit(topic, joins: {key => [entry]}, arrived: arrived ? [key] : [] of String)
        entry
      end

      # Removes the metas *key* tracked from this node, or only *ref*. Returns what was removed.
      def untrack(topic : String, key : String, ref : String? = nil) : Array(Meta)
        removed, departed = with_key(key) do
          gone = release(topic) { |meta| meta.key == key && (ref.nil? || meta.ref == ref) }
          delete_or_restore(topic, gone)
          {gone, !gone.empty? && !store.present?(topic, key, store.now, ttl)}
        end
        emit(topic, leaves: removed.group_by(&.key), departed: departed ? [key] : [] of String)
        removed
      end

      # Replaces the meta *ref* of *key* with new data: the new one is tracked before the old one goes, so the key
      # never departs and arrives again. Returns nil when this node does not own *ref*.
      def update(topic : String, key : String, ref : String, meta = nil) : Meta?
        return unless owns?(topic, ref)
        track(topic, key, meta).tap { untrack(topic, key, ref) }
      end

      # The live metas of *topic* from every node, by key, oldest first.
      def list(topic : String) : Hash(String, Array(Meta))
        verify_topic(topic)
        store.live(topic, store.now, ttl).group_by(&.key).transform_values(&.sort_by! { |meta| {meta.joined_at, meta.ref} })
      end

      # Delivers the diffs of *topic* (from every node) to the block, and keeps this node watching the topic until
      # the subscription is cancelled.
      def subscribe(topic : String, &handler : Diff ->) : Subscription
        watch = watch(topic)
        events = pub_sub.subscribe(Presence.channel_for(topic)) do |message|
          decode(message).try { |diff| handler.call(diff) }
        end
        Subscription.new(events, watch)
      end

      # Starts watching *topic*: this node follows its diffs and, on every sweep, publishes the joins and leaves
      # the diffs did not tell it about. Watches are counted per topic; the topic is dropped when the last `Watch`
      # is cancelled.
      def watch(topic : String) : Watch
        verify_topic(topic)
        token = @mutex.synchronize { join_locked(topic) }
        return Watch.new(self, topic, token) if token
        subscription = pub_sub.subscribe(Presence.channel_for(topic)) { |message| decode(message).try { |diff| absorb(topic, diff) } }
        snapshot = store.live(topic, store.now, ttl).to_h { |meta| {meta.ref, meta} }
        token, raced = @mutex.synchronize do
          if joined = join_locked(topic)
            {joined, true}
          else
            @epoch += 1
            @watchers[topic] = 1
            @tokens[topic] = @epoch
            @watching[topic] = subscription
            @seen[topic] = snapshot
            {@epoch, false}
          end
        end
        subscription.cancel if raced
        Watch.new(self, topic, token)
      end

      # Deprecated: cancel the `Watch` or `Subscription` instead. Drops every claim on *topic* at once, the ones of
      # other holders included.
      def unwatch(topic : String) : Nil
        @mutex.synchronize { forget_watch(topic) }.try(&.cancel)
      end

      def watching?(topic : String) : Bool
        @mutex.synchronize { @watchers.has_key?(topic) }
      end

      # :nodoc: Gives a `Watch` back; a claim whose *token* no longer names the topic's watch (it was dropped, or
      # dropped and started again) is ignored.
      def release_watch(topic : String, token : Int64) : Nil
        subscription = @mutex.synchronize do
          next if @tokens[topic]? != token || !(count = @watchers[topic]?)
          if count > 1
            @watchers[topic] = count - 1
            next
          end
          forget_watch(topic)
        end
        subscription.try(&.cancel)
      end

      # One heartbeat: renews the lease, re-asserts the metas owned here (a Redis flush or a long pause cannot
      # lose them) and publishes what changed in the watched topics.
      def sweep : Nil
        store.renew(node, store.now + ttl)
        store.prune_leases(store.now, ttl)
        reassert
        watched.each { |topic| reconcile(topic) }
      end

      # Removes everything this node tracked and stops the heartbeat. A later `track` starts it again.
      def shutdown : Nil
        stopped = @mutex.synchronize { @alive = false; @stopped.tap { @stopped = ::Channel(Nil).new } }
        stopped.close unless stopped.closed?
        owned.each_key { |topic| untrack_topic(topic) }
        drop_watches
        store.shutdown
      end

      def pub_sub : PubSub::Backend
        @pub_sub || PubSub.backend
      end

      private def untrack_topic(topic : String) : Nil
        owned[topic]?.try(&.map(&.key).uniq!).try(&.each { |key| untrack(topic, key) })
      rescue ex
        Log.for("Azu::Presence").warn(exception: ex) { "Could not untrack #{topic} on shutdown" }
      end

      private def verify(topic : String, key : String, data : JSON::Any) : Nil
        verify_topic(topic)
        raise LimitExceeded.new("presence key is #{key.bytesize} bytes, the limit is #{MAX_KEY_BYTES}") if key.bytesize > MAX_KEY_BYTES
        raise ArgumentError.new("presence key must not contain U+001F") if key.includes?('\u001f')
        size = data.to_json.bytesize
        raise LimitExceeded.new("presence meta is #{size} bytes, the limit is #{@max_meta_bytes}") if size > @max_meta_bytes
      end

      private def verify_topic(topic : String) : Nil
        raise ArgumentError.new("presence topic must not contain U+001F") if topic.includes?('\u001f')
        raise LimitExceeded.new("presence topic is #{topic.bytesize} bytes, the limit is #{MAX_TOPIC_BYTES}") if topic.bytesize > MAX_TOPIC_BYTES
      end

      # Writes to the store of one key go through the lock of its stripe, so a track, an untrack and the re-assert
      # of the sweep never interleave for that key (an untracked meta cannot be put back).
      private def with_key(key : String, &)
        @locks[stripe(key)].synchronize { yield }
      end

      private def stripe(key : String) : Int32
        (key.hash % STRIPES).to_i
      end

      private def reserve(topic : String, key : String, data : JSON::Any, now : Time) : Meta
        @mutex.synchronize do
          entries = @own.sum(0) { |_, metas| metas.size }
          raise LimitExceeded.new("this node already tracks #{entries} presences, the limit is #{@max_entries}") if entries >= @max_entries
          @counter += 1
          Meta.new("#{node}.#{@counter}", node, key, data, now.to_unix_ms).tap do |meta|
            (@own[topic] ||= {} of String => Meta)[meta.ref] = meta
          end
        end
      end

      private def put_or_release(topic : String, meta : Meta) : Nil
        store.put(topic, meta)
      rescue ex
        release(topic) { |candidate| candidate.ref == meta.ref }
        raise ex
      end

      private def delete_or_restore(topic : String, metas : Array(Meta)) : Nil
        metas.each { |meta| store.delete(topic, meta) }
      rescue ex
        @mutex.synchronize { metas.each { |meta| (@own[topic] ||= {} of String => Meta)[meta.ref] = meta } }
        raise ex
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

      private def owns?(topic : String, ref : String) : Bool
        @mutex.synchronize { @own[topic]?.try(&.has_key?(ref)) || false }
      end

      private def owned : Hash(String, Array(Meta))
        @mutex.synchronize { @own.transform_values(&.values) }
      end

      private def watched : Array(String)
        @mutex.synchronize { @watchers.keys }
      end

      # Counts a claim on an already watched topic and returns its token; nil when nobody watches it yet.
      # The caller holds @mutex.
      private def join_locked(topic : String) : Int64?
        return unless count = @watchers[topic]?
        @watchers[topic] = count + 1
        @tokens[topic]
      end

      # Forgets a watched topic and returns its subscription to cancel. The caller holds @mutex.
      private def forget_watch(topic : String) : PubSub::Subscription?
        @watchers.delete(topic)
        @tokens.delete(topic)
        @reading.delete(topic)
        @seen.delete(topic)
        @watching.delete(topic)
      end

      private def drop_watches : Nil
        subscriptions = @mutex.synchronize do
          @watchers.keys.compact_map { |topic| forget_watch(topic) }
        end
        subscriptions.each(&.cancel)
      end

      # Puts back the metas the store lost (a flush, an eviction while this node looked dead) and extends the
      # retention of the others. One read per topic; the writes of a stripe of keys happen under its lock and only
      # for metas that are still owned there, so an untrack that ran after the snapshot is never undone.
      private def reassert : Nil
        owned.each do |topic, metas|
          stored = store.refs(topic).to_set
          metas.group_by { |meta| stripe(meta.key) }.each do |index, group|
            @locks[index].synchronize { reassert_stripe(topic, group.select { |meta| owns?(topic, meta.ref) }, stored) }
          end
        end
      end

      private def reassert_stripe(topic : String, metas : Array(Meta), stored : Set(String)) : Nil
        missing, present = metas.partition { |meta| !stored.includes?(meta.ref) }
        missing.each { |meta| store.put(topic, meta) }
        store.refresh(topic, present) unless present.empty?
      end

      # Publishes what the store holds and this node has not seen (joins), and what it saw and is gone (leaves).
      # Diffs absorbed while the store was being read win: a meta is only a leave if it was seen before the read,
      # and a meta whose leave arrived during the read is not announced as a join.
      private def reconcile(topic : String) : Nil
        before = @mutex.synchronize do
          next unless seen = @seen[topic]?
          @reading[topic] = Set(String).new
          seen.keys
        end
        return unless before
        begin
          current = store.live(topic, store.now, ttl).to_h { |meta| {meta.ref, meta} }
        rescue ex
          @mutex.synchronize { @reading.delete(topic) }
          raise ex
        end
        delta = settle(topic, before, current)
        emit(topic, **delta) if delta
      end

      private def settle(topic : String, before : Array(String), current : Hash(String, Meta))
        @mutex.synchronize do
          removed = @reading.delete(topic) || Set(String).new
          next unless seen = @seen[topic]?
          joined = current.reject { |ref, _| seen.has_key?(ref) || removed.includes?(ref) }.values
          gone = before.select { |ref| seen.has_key?(ref) && !current.has_key?(ref) }.map { |ref| seen[ref] }
          keys_before = seen.each_value.map(&.key).to_set
          gone.each { |meta| seen.delete(meta.ref) }
          joined.each { |meta| seen[meta.ref] = meta }
          keys_after = seen.each_value.map(&.key).to_set
          joins = joined.group_by(&.key)
          leaves = gone.group_by(&.key)
          {joins: joins, leaves: leaves, arrived: joins.keys.reject { |key| keys_before.includes?(key) },
           departed: leaves.keys.reject { |key| keys_after.includes?(key) }}
        end
      end

      # Folds a diff into what this node has seen, by ref, so it does not publish it again.
      private def absorb(topic : String, diff : Diff) : Nil
        @mutex.synchronize do
          next unless seen = @seen[topic]?
          reading = @reading[topic]?
          diff.leaves.each_value(&.each { |meta| seen.delete(meta.ref); reading.try(&.add(meta.ref)) })
          diff.joins.each_value(&.each { |meta| seen[meta.ref] = meta })
        end
      end

      private def decode(message : PubSub::Message) : Diff?
        Diff.from_json(message.payload)
      rescue JSON::ParseException | JSON::SerializableError
        Log.for("Azu::Presence").warn { "Dropped a malformed presence diff on #{message.topic}" }
      end

      private def emit(topic : String, joins = {} of String => Array(Meta), leaves = {} of String => Array(Meta),
                       arrived = [] of String, departed = [] of String) : Nil
        return if joins.empty? && leaves.empty?
        sequence = @mutex.synchronize { @sequence += 1 }
        diff = Diff.new(joins, leaves, arrived, departed, node, sequence)
        absorb(topic, diff)
        pub_sub.broadcast(Presence.channel_for(topic), diff.to_json)
      rescue ex
        Log.for("Azu::Presence").warn(exception: ex) { "Could not publish the presence diff of #{topic}" }
      end

      private def ensure_alive : Nil
        stopped = @mutex.synchronize { @alive ? nil : (@alive = true; @stopped) }
        return unless stopped
        store.renew(node, store.now + ttl)
        interval = @interval
        Azu.spawn_scoped("azu-presence") { beat(interval, stopped) } if interval
      rescue ex
        @mutex.synchronize { @alive = false }
        raise ex
      end

      private def beat(interval : Time::Span, stopped : ::Channel(Nil)) : Nil
        loop do
          select
          when stopped.receive?
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
