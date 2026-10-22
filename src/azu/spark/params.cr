require "json"
require "uri"
require "./errors"

module Azu
  module Spark
    # The payload of a client event, or the page parameters handed to `mount`.
    #
    # Values are looked up with an explicit type. A mismatch raises `BadRequest`, which the
    # connection reports to the client without touching component state:
    #
    # ```
    # params.fetch("count", Int32) # "3" and 3 both work
    # params.fetch("tags", Array(String))
    # params.fetch("page", Int32, 1) # default when absent
    # ```
    #
    # A parameter typed as an `Azu::Request` receives the whole payload and is built with the
    # request's own deserialization, so its validations apply to form submissions.
    struct Params
      getter data : Hash(String, JSON::Any)

      def initialize(@data : Hash(String, JSON::Any) = {} of String => JSON::Any)
      end

      def self.from_strings(values : Hash(String, String)) : Params
        new(values.transform_values { |value| JSON::Any.new(value) })
      end

      def [](key : String) : JSON::Any
        @data[key]? || raise BadRequest.new("missing parameter '#{key}'")
      end

      def []?(key : String) : JSON::Any?
        @data[key]?
      end

      def has_key?(key : String) : Bool
        @data.has_key?(key)
      end

      def keys : Array(String)
        @data.keys
      end

      def empty? : Bool
        @data.empty?
      end

      def fetch(key : String, type : T.class) : T forall T
        {% if T < Azu::Request %}
          request(T)
        {% else %}
          value = @data[key]?
          {% if T.nilable? %}
            return nil if value.nil? || value.raw.nil?
          {% end %}
          raise BadRequest.new("missing parameter '#{key}'") if value.nil?
          Coercion.convert(value, key, {{ T.union_types.reject { |type| type == Nil }.first }})
        {% end %}
      end

      def fetch(key : String, type : T.class, default : T) : T forall T
        {% if T < Azu::Request %}
          request(T)
        {% else %}
          has_key?(key) ? fetch(key, T) : default
        {% end %}
      end

      # Builds an `Azu::Request` from the payload, as if it had been submitted as a form.
      def request(type : T.class) : T forall T
        form = URI::Params.build do |builder|
          @data.each do |name, value|
            if array = value.as_a?
              array.each { |item| builder.add(name, item.raw.to_s) }
            else
              builder.add(name, value.raw.to_s)
            end
          end
        end
        T.from_www_form(form)
      rescue ex : URI::SerializableError | JSON::ParseException | ArgumentError
        raise BadRequest.new("invalid #{T.name.split("::").last}")
      end

      def to_json(builder : JSON::Builder) : Nil
        @data.to_json(builder)
      end
    end
  end
end
