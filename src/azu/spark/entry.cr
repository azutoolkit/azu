require "../pub_sub"

module Azu
  module Spark
    # Runtime bookkeeping of one mounted component, kept apart from the component itself so
    # application code only sees its own model.
    class Entry
      getter component : Component
      getter id : String
      getter parent_id : String?
      getter root_id : String
      getter depth : Int32
      # Digest of the inner HTML last sent to the client; unchanged HTML is never resent.
      property digest : String = ""
      # Children embedded by the latest render, by id.
      property children : Set(String) = Set(String).new
      getter subscriptions = {} of String => PubSub::Subscription
      # Closed on unmount; stops the timers started for this component.
      getter retired = ::Channel(Nil).new

      def initialize(@component : Component, @id : String, @parent_id : String?, @root_id : String, @depth : Int32)
      end

      @mounted_at = Time.utc

      def root? : Bool
        parent_id.nil?
      end

      def age : Time::Span
        Time.utc - @mounted_at
      end

      def retire : Nil
        @retired.close unless @retired.closed?
        subscriptions.each_value(&.cancel)
        subscriptions.clear
      end
    end
  end
end
