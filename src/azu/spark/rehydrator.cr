require "log"
require "./configuration"
require "./snapshot"

module Azu
  module Spark
    # Brings the components of a page back to the state of an earlier connection: `load` opens the
    # snapshot a client sent with its `join`, and `restore` hands each component its state as the
    # session mounts it (children are mounted while the parent renders, so states wait here until
    # their turn).
    class Rehydrator
      def initialize(@config : Configuration)
        @pending = {} of String => Snapshot::Member
      end

      def load(token : String?, root_id : String, session : Hash(String, String)) : Nil
        return unless token
        @pending.merge!(Snapshot.open(token, root_id, session, @config.secret, @config.max_snapshot_size))
      end

      # Restores *component* (mounted as *id*) from its pending state, if any. A state recorded for
      # another class is refused: the snapshot does not describe this component.
      def restore(component : Component, id : String) : Nil
        return unless member = @pending.delete(id)
        unless member.type == component.class.name
          raise InvalidSnapshot.new("snapshot of #{id} was taken from #{member.type}, not #{component.class.name}")
        end
        component.__spark_restore(member.state)
      rescue JSON::ParseException | JSON::SerializableError
        Log.for("Azu::Spark").warn { "State snapshot of #{component.class.name} no longer fits its declaration" }
      end

      def clear : Nil
        @pending.clear
      end
    end
  end
end
