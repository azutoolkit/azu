module Azu
  module Presence
    # Opt-in for an `Azu::Channel`: presence tracked through the channel ends with its connection, however the
    # socket ends (close frame, dropped peer, raising handler), because `teardown` untracks it.
    #
    # ```
    # class RoomChannel < Azu::Channel
    #   include Azu::Presence::Tracked
    #
    #   def on_connect
    #     presence_updates("room:1") # forwards every diff to this socket, its own join included
    #     track_presence("room:1", params["user"], {device: "web"})
    #   end
    # end
    # ```
    module Tracked
      @presence_tracked = [] of {String, Meta}
      @presence_watches = {} of String => Watch
      @presence_mutex = Mutex.new
      @presence_closed = false

      def track_presence(topic : String, key : String, meta = nil) : Meta
        Presence.track(topic, key, meta).tap do |entry|
          closed = @presence_mutex.synchronize { @presence_closed.tap { |done| @presence_tracked << {topic, entry} unless done } }
          Presence.untrack(topic, key, entry.ref) if closed
        end
      end

      # Subscribes this socket to the diffs of *topic*; they reach `on_broadcast` as JSON.
      def presence_updates(topic : String) : Nil
        return if @presence_mutex.synchronize { @presence_closed }
        watch = Presence.default.watch(topic)
        kept = @presence_mutex.synchronize do
          next false if @presence_closed || @presence_watches.has_key?(topic)
          @presence_watches[topic] = watch
          true
        end
        watch.cancel unless kept
        return if @presence_mutex.synchronize { @presence_closed }
        begin
          subscribe_topic(Presence.channel_for(topic))
        rescue error
          # The watch this call registered would otherwise stay, with no subscription delivering its diffs
          @presence_mutex.synchronize { @presence_watches.delete(topic) }.try(&.cancel) if kept
          raise error
        end
      end

      # Untracks last: a slow store must not hold up closing the socket.
      def teardown : Nil
        super
      ensure
        untrack_presence
      end

      private def untrack_presence : Nil
        tracked, watches = @presence_mutex.synchronize do
          @presence_closed = true
          {@presence_tracked.dup.tap { @presence_tracked.clear }, @presence_watches.values.tap { @presence_watches = {} of String => Watch }}
        end
        watches.each(&.cancel)
        tracked.each do |topic, entry|
          Presence.untrack(topic, entry.key, entry.ref)
        rescue ex
          Log.for("Azu::Presence").warn(exception: ex) { "Could not untrack #{entry.key} from #{topic}" }
        end
      end
    end
  end
end
