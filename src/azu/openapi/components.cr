require "./value"

module Azu::OpenAPI
  # The named schemas a document shares: every `JSON::Serializable` type that appears in a contract
  # is described once here and referenced from where it is used.
  class Components
    getter schemas = Map.new

    # A `$ref` to the schema of `type_name`, building it with the block the first time. The name is
    # taken before the block runs, so a type that refers to itself terminates.
    def reference(type_name : String, & : -> Map) : Map
      name = OpenAPI.identifier(type_name)
      unless @schemas.has_key?(name)
        @schemas[name] = Map.new
        @schemas[name] = yield
      end
      Map{"$ref" => "#/components/schemas/#{name}"}
    end

    def merge(other : Components) : Nil
      @schemas.merge!(other.schemas)
    end
  end
end
