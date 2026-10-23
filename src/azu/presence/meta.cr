require "json"

module Azu
  module Presence
    # One tracked presence of a key: a device, socket or tab. *ref* is unique across the cluster
    # (`<node>.<counter>`), so diffs can be applied idempotently.
    struct Meta
      include JSON::Serializable

      getter ref : String
      getter node : String
      getter key : String
      getter data : JSON::Any
      # Unix milliseconds; orders the metas of a key.
      getter joined_at : Int64

      def initialize(@ref : String, @node : String, @key : String, @data : JSON::Any, @joined_at : Int64)
      end
    end

    # What one change did to a topic. `joins` and `leaves` carry every meta added or removed, keyed by user;
    # `arrived` and `departed` name the keys that went from absent to present and back. `node` and `seq` identify the
    # publisher and number its diffs 1, 2, 3...: a gap in the `seq` of one `node` means diffs were missed, so call
    # `list` again. A node restarts at 1 under a new id.
    struct Diff
      include JSON::Serializable

      getter joins : Hash(String, Array(Meta))
      getter leaves : Hash(String, Array(Meta))
      getter arrived : Array(String)
      getter departed : Array(String)
      getter node : String = ""
      getter seq : Int64 = 0_i64

      def initialize(@joins = {} of String => Array(Meta), @leaves = {} of String => Array(Meta),
                     @arrived = [] of String, @departed = [] of String, @node = "", @seq = 0_i64)
      end

      def empty? : Bool
        joins.empty? && leaves.empty?
      end
    end
  end
end
