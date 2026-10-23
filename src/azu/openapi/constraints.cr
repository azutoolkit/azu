require "./value"

module Azu::OpenAPI
  # What `validate` options say about a field, written into the JSON Schema of that field.
  #
  # The generated code calls one method per option with the value the option was declared with
  # (`validate age, gte: 0` is `gte(schema, 0)`). What a keyword means depends on the type of the
  # field: a size is a length for a string, an item count for an array.
  module Constraints
    SIZE_KEYWORDS = {
      "string" => {"minLength", "maxLength"},
      "array"  => {"minItems", "maxItems"},
      "object" => {"minProperties", "maxProperties"},
    }

    def self.presence(schema : Map) : Nil
      size(schema, 1..)
    end

    def self.size(schema : Map, exact : Int) : Nil
      size(schema, exact..exact)
    end

    def self.size(schema : Map, range : Range) : Nil
      return unless keywords = SIZE_KEYWORDS[schema["type"]?]?
      min, max = bounds(range)
      raise_floor(schema, keywords[0], min) if min
      lower_ceiling(schema, keywords[1], max) if max
    end

    def self.gt(schema : Map, bound : Int | Float) : Nil
      schema["exclusiveMinimum"] = number(bound)
    end

    def self.gte(schema : Map, bound : Int | Float) : Nil
      schema["minimum"] = number(bound)
    end

    def self.lt(schema : Map, bound : Int | Float) : Nil
      schema["exclusiveMaximum"] = number(bound)
    end

    def self.lte(schema : Map, bound : Int | Float) : Nil
      schema["maximum"] = number(bound)
    end

    def self.eq(schema : Map, expected : String | Int | Float | Bool) : Nil
      schema["const"] = scalar(expected)
    end

    def self.inclusion(schema : Map, allowed : Array) : Nil
      schema["enum"] = allowed.map { |element| scalar(element).as(Value) }
    end

    def self.inclusion(schema : Map, range : Range) : Nil
      min, max = bounds(range)
      schema["minimum"] = min.to_i64 if min
      schema["maximum"] = max.to_i64 if max
    end

    def self.exclusion(schema : Map, forbidden : Array) : Nil
      schema["not"] = Map{"enum" => forbidden.map { |element| scalar(element).as(Value) }}
    end

    # Only a pattern that means the same to an ECMA-262 engine is written: `\A`, `\z` and `\Z` become `^` and
    # `$`, and a pattern with options, named groups, inline flags or Crystal-only escapes is left out.
    def self.match(schema : Map, pattern : Regex) : Nil
      return unless pattern.options.none?
      portable = Pattern.portable(pattern.source)
      schema["pattern"] = portable if portable
    end

    # The options that carry no JSON Schema meaning, or none that can be told here, are ignored.
    def self.inclusion(schema : Map, other) : Nil
    end

    def self.exclusion(schema : Map, other) : Nil
    end

    def self.gt(schema : Map, other) : Nil
    end

    def self.gte(schema : Map, other) : Nil
    end

    def self.lt(schema : Map, other) : Nil
    end

    def self.lte(schema : Map, other) : Nil
    end

    def self.eq(schema : Map, other) : Nil
    end

    def self.match(schema : Map, other) : Nil
    end

    def self.size(schema : Map, other) : Nil
    end

    # The smallest and largest value a range of integers allows; nil where it is open.
    private def self.bounds(range : Range(B, E)) : Tuple(Int64?, Int64?) forall B, E
      {% if (B <= Int || B <= Nil) && (E <= Int || E <= Nil) %}
        min = range.begin.try(&.to_i64)
        max = range.end.try { |last| range.exclusive? ? last.to_i64 - 1 : last.to_i64 }
        {min, max}
      {% else %}
        {nil, nil}
      {% end %}
    end

    # A keyword that sets a lower limit never loosens one that is already stricter.
    private def self.raise_floor(schema : Map, keyword : String, floor : Int64) : Nil
      current = schema[keyword]?.as?(Int64)
      schema[keyword] = floor if current.nil? || floor > current
    end

    private def self.lower_ceiling(schema : Map, keyword : String, ceiling : Int64) : Nil
      current = schema[keyword]?.as?(Int64)
      schema[keyword] = ceiling if current.nil? || ceiling < current
    end

    private def self.number(bound : Int) : Value
      bound.to_i64
    end

    private def self.number(bound : Float) : Value
      bound.to_f64
    end

    private def self.scalar(value : Int) : Value
      value.to_i64
    end

    private def self.scalar(value : Float) : Value
      value.to_f64
    end

    private def self.scalar(value : String | Bool) : Value
      value
    end

    private def self.scalar(value : Symbol) : Value
      value.to_s
    end

    private def self.scalar(value) : Value
      value.to_s
    end
  end
end

module Azu::OpenAPI::Constraints
  # Translates the source of a Crystal regular expression to ECMA-262, or nil when it cannot.
  module Pattern
    ANCHORS     = {'A' => "^", 'z' => "$", 'Z' => "$"}
    UNSUPPORTED = "hHRXGKaeQEpP"

    def self.portable(source : String) : String?
      result = String::Builder.new
      index = 0
      while index < source.size
        if source[index] == '\\'
          piece = escape(source[index + 1]?) || return
          index += 2
        else
          return if unsupported_group?(source, index)
          piece = source[index].to_s
          index += 1
        end
        result << piece
      end
      result.to_s
    end

    private def self.escape(escaped : Char?) : String?
      return unless escaped
      return if UNSUPPORTED.includes?(escaped)
      ANCHORS[escaped]? || "\\#{escaped}"
    end

    # Groups with a name, flags or other extensions, and POSIX classes, have no ECMA-262 form.
    private def self.unsupported_group?(source : String, index : Int32) : Bool
      following = source[index + 1]?
      case source[index]
      when '(' then following == '?' && !source[index + 2]?.in?(':', '=', '!')
      when '[' then following == ':'
      else          false
      end
    end
  end
end
