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
      @presence_mutex = Mutex.new

      def track_presence(topic : String, key : String, meta = nil) : Meta
        Presence.track(topic, key, meta).tap do |entry|
          @presence_mutex.synchronize { @presence_tracked << {topic, entry} }
        end
      end

      # Subscribes this socket to the diffs of *topic*; they reach `on_broadcast` as JSON.
      def presence_updates(topic : String) : Nil
        Presence.default.watch(topic)
        subscribe_topic(Presence.channel_for(topic))
      end

      # Untracks last: a slow store must not hold up closing the socket.
      def teardown : Nil
        super
      ensure
        untrack_presence
      end

      private def untrack_presence : Nil
        tracked = @presence_mutex.synchronize { @presence_tracked.dup.tap { @presence_tracked.clear } }
        tracked.each do |topic, entry|
          Presence.untrack(topic, entry.key, entry.ref)
        rescue ex
          Log.for("Azu::Presence").warn(exception: ex) { "Could not untrack #{entry.key} from #{topic}" }
        end
      end
    end
  end
end
