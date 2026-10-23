require "uuid"
require "json"
require "./components"
require "./constraints"

module Azu::OpenAPI
  # JSON Schema (2020-12, as OpenAPI 3.1 uses it) for Crystal types, found at compile time.
  #
  # Understood: strings, integers, floats, booleans, `Time` (date-time), `UUID`, enums (the
  # underscored member names `to_json` writes), `Array`, `Set`, `Hash(String, _)`, nilable types,
  # unions and `JSON::Serializable` classes and structs, which become named `components`. Any other
  # type is described as `{}`, which allows anything: a schema that is too loose is better than a
  # wrong one.
  module Schema
    # How the fields of a request are read: from a JSON body, or from a query string or form.
    struct Body
    end

    # :ditto:
    struct Form
    end

    def self.of(type : T.class, components : Components) : Map forall T
      {% if T == Nil %}
        Map{"type" => "null"}
      {% elsif T.union? %}
        {% present = T.union_types.reject { |member| member == Nil } %}
        {% if present.size == 1 %}
          of({{present[0]}}, components)
        {% else %}
          Map{"anyOf" => [{% for member in present %}of({{member}}, components).as(Value),{% end %}] of Value}
        {% end %}
      {% elsif T == String %}
        Map{"type" => "string"}
      {% elsif T == Bool %}
        Map{"type" => "boolean"}
      {% elsif T <= Int %}
        {% if T == Int32 %}
          Map{"type" => "integer", "format" => "int32"}
        {% elsif T == Int64 %}
          Map{"type" => "integer", "format" => "int64"}
        {% else %}
          Map{"type" => "integer"}
        {% end %}
      {% elsif T == Float32 %}
        Map{"type" => "number", "format" => "float"}
      {% elsif T <= Float %}
        Map{"type" => "number", "format" => "double"}
      {% elsif T == Time %}
        Map{"type" => "string", "format" => "date-time"}
      {% elsif T == UUID %}
        Map{"type" => "string", "format" => "uuid"}
      {% elsif T <= Enum %}
        {% if T.annotation(Flags) %}
          Map{"type" => "array", "items" => Map{"type" => "string", "enum" => member_names({{T}})}}
        {% else %}
          Map{"type" => "string", "enum" => member_names({{T}})}
        {% end %}
      {% elsif T.name(generic_args: false) == "Array" || T.name(generic_args: false) == "Set" %}
        Map{"type" => "array", "items" => of({{T.type_vars[0]}}, components)}
      {% elsif T.name(generic_args: false) == "Hash" && T.type_vars[0] == String %}
        Map{"type" => "object", "additionalProperties" => of({{T.type_vars[1]}}, components)}
      {% elsif T < JSON::Serializable %}
        components.reference({{T.name.stringify}}) { object({{T}}, components) }
      {% else %}
        Map.new
      {% end %}
    end

    # How `to_json` writes the members of an enum.
    private def self.member_names(type : T.class) : Array(Value) forall T
      T.names.map { |name| name.underscore.as(Value) }
    end

    # The object schema of the instance variables of `type`, with the constraints its `validate`
    # calls record. A variable is required unless its type is nilable or it has a default, or when a
    # `presence` or `required` validation says it must be there.
    #
    # A `validate` argument is used only when it is a literal (or a constant of `type` that holds one): numbers,
    # strings, booleans, symbols and regexes, and ranges and arrays of those. Anything computed cannot be
    # read at compile time, so its constraint is left out instead of stopping the build.
    #
    # `Body` reads the instance variables the way `JSON::Serializable` does, `Form` the way
    # `URI::Params::Serializable` does (the variable name is always the key). A field with a
    # `converter:` or a JSON `root:` is described as `{}`: what it holds is not its type.
    def self.object(type : T.class, components : Components, encoding : E.class = Body) forall T, E
      properties = Map.new
      required = [] of Value
      {% for ivar in T.instance_vars %}
        {% form = E == Form %}
        {% field = form ? ivar.annotation(URI::Params::Field) : ivar.annotation(JSON::Field) %}
        {% unless field && (field[:ignore] || (form && field[:ignore_deserialize])) %}
          {% key = !form && field && field[:key].is_a?(StringLiteral) ? field[:key] : ivar.name.stringify %}
          {% opaque = field && (field[:converter] || (!form && field[:root])) %}
          property = {% if opaque %}Map.new{% else %}of({{ivar.type}}, components){% end %}
          must_exist = {{!ivar.type.nilable? && !ivar.has_default_value?}}
          {% if T.type_vars.empty? && T.has_constant?("SCHEMA_VALIDATIONS") %}
            {% for name, options in T.constant("SCHEMA_VALIDATIONS") %}
              {% if name.stringify == ivar.name.stringify %}
                {% for predicate, option in options %}
                  {% expected = option %}
                  {% if option.is_a?(Path) && option.names.size == 1 && T.has_constant?(option.names[0]) %}
                    {% expected = T.constant(option.names[0]) %}
                  {% end %}
                  {% scalar = expected.is_a?(NumberLiteral) || expected.is_a?(StringLiteral) || expected.is_a?(BoolLiteral) || expected.is_a?(SymbolLiteral) || expected.is_a?(RegexLiteral) %}
                  {% range = expected.is_a?(RangeLiteral) && (expected.begin.is_a?(NumberLiteral) || expected.begin.is_a?(NilLiteral) || expected.begin.is_a?(Nop)) && (expected.end.is_a?(NumberLiteral) || expected.end.is_a?(NilLiteral) || expected.end.is_a?(Nop)) %}
                  {% list = expected.is_a?(ArrayLiteral) && expected.all? { |element| element.is_a?(NumberLiteral) || element.is_a?(StringLiteral) || element.is_a?(SymbolLiteral) || element.is_a?(BoolLiteral) } %}
                  {% plain = scalar || range || list %}
                  {% if predicate.stringify == "presence" %}
                    Constraints.presence(property)
                    must_exist = true
                  {% elsif predicate.stringify == "required" %}
                    must_exist = true
                  {% elsif !plain %}
                  {% elsif predicate.stringify == "in" %}
                    Constraints.inclusion(property, {{expected}})
                  {% elsif predicate.stringify == "exclude" %}
                    Constraints.exclusion(property, {{expected}})
                  {% elsif %w(size eq gt gte lt lte match).includes?(predicate.stringify) %}
                    Constraints.{{predicate.id}}(property, {{expected}})
                  {% end %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
          properties[{{key}}] = property
          required << {{key}} if must_exist
        {% end %}
      {% end %}

      schema = Map{"type" => "object", "properties" => properties}
      schema["required"] = required unless required.empty?
      schema
    end
  end
end
