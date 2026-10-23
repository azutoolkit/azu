require "json"

module Azu
  # Generates an OpenAPI 3.1 document from the contracts of an app's endpoints. See `OpenAPI.document`
  # and `OpenAPI::Handler`.
  module OpenAPI
    # A JSON value as the document is assembled from: objects, arrays and scalars.
    alias Value = String | Int64 | Float64 | Bool | Nil | Array(Value) | Hash(String, Value)

    # A JSON object.
    alias Map = Hash(String, Value)

    # A type name as a component name or operation id: `Shop::Page(Shop::User)` is `Shop.Page.Shop.User`,
    # since component names are limited to letters, digits, `.`, `-` and `_`.
    def self.identifier(type_name : String) : String
      type_name.gsub(/[^a-zA-Z0-9_-]+/, ".").strip('.')
    end

    # `value` as JSON with the keys of every object sorted, so the same app always yields the same bytes.
    def self.encode(value : Value, pretty : Bool = false) : String
      String.build do |io|
        builder = JSON::Builder.new(io)
        builder.indent = 2 if pretty
        builder.document { write(value, builder) }
      end
    end

    # :nodoc:
    def self.write(value : Value, json : JSON::Builder) : Nil
      case value
      in Hash
        json.object do
          value.keys.sort!.each { |key| json.field(key) { write(value[key], json) } }
        end
      in Array
        json.array { value.each { |element| write(element, json) } }
      in String  then json.string(value)
      in Int64   then json.number(value)
      in Float64 then json.number(value)
      in Bool    then json.bool(value)
      in Nil     then json.null
      end
    end
  end
end
