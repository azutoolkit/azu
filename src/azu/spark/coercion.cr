require "json"
require "./errors"

module Azu
  module Spark
    # Converts the loosely typed JSON of a client payload into the exact type a handler
    # declares. Form fields arrive as strings, so "3" is accepted for an `Int32` and "on" for a
    # `Bool`. Anything that does not fit raises `BadRequest`; unsupported target types are a
    # compile error.
    module Coercion
      def self.convert(value : JSON::Any, key : String, type : String.class) : String
        case raw = value.raw
        when String               then raw
        when Int64, Float64, Bool then raw.to_s
        else                           mismatch(key, "a string")
        end
      end

      {% for int in %w(Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64) %}
        def self.convert(value : JSON::Any, key : String, type : {{ int.id }}.class) : {{ int.id }}
          {{ int.id }}.new(integer(value, key))
        rescue OverflowError
          mismatch(key, "an integer within range")
        end
      {% end %}

      def self.convert(value : JSON::Any, key : String, type : Float64.class) : Float64
        float(value, key)
      end

      def self.convert(value : JSON::Any, key : String, type : Float32.class) : Float32
        float(value, key).to_f32
      end

      def self.convert(value : JSON::Any, key : String, type : Bool.class) : Bool
        case raw = value.raw
        when Bool  then raw
        when Int64 then raw != 0
        when String
          case raw.downcase
          when "true", "on", "1", "yes"      then true
          when "false", "off", "0", "no", "" then false
          else                                    mismatch(key, "a boolean")
          end
        else mismatch(key, "a boolean")
        end
      end

      # A single form value is accepted where a list is expected.
      def self.convert(value : JSON::Any, key : String, type : Array(U).class) : Array(U) forall U
        (value.as_a? || [value]).map { |item| convert(item, key, U) }
      end

      def self.convert(value : JSON::Any, key : String, type : T.class) : T forall T
        {% if T < Enum %}
          T.parse?(convert(value, key, String)) || mismatch(key, "one of #{T.names.join(", ")}")
        {% else %}
          {% raise "Spark event parameters of type #{T} are not supported: use String, Int*, UInt*, Float*, Bool, an Enum, an Array of those or an Azu::Request" %}
        {% end %}
      end

      private def self.integer(value : JSON::Any, key : String) : Int64
        case raw = value.raw
        when Int64   then raw
        when Float64 then raw.finite? && raw == raw.floor && raw.abs < 9.0e15 ? raw.to_i64 : mismatch(key, "an integer")
        when String  then raw.strip.to_i64? || mismatch(key, "an integer")
        else              mismatch(key, "an integer")
        end
      end

      private def self.float(value : JSON::Any, key : String) : Float64
        case raw = value.raw
        when Float64 then raw
        when Int64   then raw.to_f64
        when String  then raw.strip.to_f64? || mismatch(key, "a number")
        else              mismatch(key, "a number")
        end
      end

      private def self.mismatch(key : String, expected : String) : NoReturn
        raise BadRequest.new("parameter '#{key}' must be #{expected}")
      end
    end
  end
end
