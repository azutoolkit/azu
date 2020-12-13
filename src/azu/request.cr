require "mime"

module Azu
  # Every HTTP request message has a specific form:
  #
  # ```text
  # POST /path HTTP/1.1
  # Host: example.com
  #
  # foo=bar&baz=bat
  # ```
  #
  # A HTTP message is either a request from a client to a server or a response from a server to a client
  # The `Azu::Request` represents a client request and it provides additional helper methods to access different
  # parts of the HTTP Request extending the Crystal `HTTP::Request` standard library class.
  # These methods are define in the `Helpers` class.
  #
  # Azu Request are design by contract in order to enforce correctness. What this means is that requests
  # are strictly typed and can have pre-conditions. With this concept Azu::Request provides a consice way
  # to type safe and validate requests objects.
  #
  # Azu Requests benefits:
  #
  # * Self documented request objects.
  # * Type safe requests and parameters
  # * Enables Focused and effective testing.
  # * Json body requests render object instances.
  #
  # Azu Requests contracts is provided by tight integration with the [Schema](https://github.com/eliasjpr/schema) shard
  #
  # ### Example Use:
  #
  # ```
  # class UserRequest
  #   include Azu::Request
  #
  #   query name : String, message: "Param name must be present.", presence: true
  # end
  # ```
  #
  # ### Initializers
  #
  # ```
  # UserRequest.from_json(pyaload: String)
  # UserRequest.new(params: Hash(String, String))
  # ```
  #
  # ### Available Methods
  #
  # ```
  # getters   - For each of the params
  # valid?    - Bool
  # validate! - True or Raise Error
  # errors    - Errors(T, S)
  # rules     - Rules(T, S)
  # params    - Original params payload
  # to_json   - Outputs JSON
  # to_yaml   - Outputs YAML
  # ```
  #
  module Request
    macro included
      CONTENT_ATTRIBUTES = {} of Nil => Nil
      FIELD_OPTIONS = {} of Nil => Nil
      CUSTOM_VALIDATORS  = {} of Nil => Nil
      
      macro finished
        include JSON::Serializable
        __process_validation
        include Schema::Validators
        __process_params
      end
    end

    macro validate(attribute, **options)
      {% FIELD_OPTIONS[attribute] = options %}
      {% CONTENT_ATTRIBUTES[attribute] = options || {} of Nil => Nil %}
    end

    macro use(*validators)
      {% for validator in validators %}
        {% CUSTOM_VALIDATORS[validator.stringify] = @type %}
      {% end %}
    end

    macro predicates
      module ::Schema
        module Validators
          {{yield}}
        end
      end
    end

    macro __process_validation
      {% CUSTOM_VALIDATORS["Schema::Rule"] = "Symbol" %}
      {% custom_validators = CUSTOM_VALIDATORS.keys.map { |v| v.id }.join("|") %}
      {% custom_types = CUSTOM_VALIDATORS.values.map { |v| v.id }.join("|") %}

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      getter rules : Schema::Rules({{custom_validators.id}}, {{custom_types.id}}) =
         Schema::Rules({{custom_validators.id}},{{custom_types.id}}).new

      def valid?
        load_validations_rules
        rules.errors.empty?
      end

      def validate!
        valid? || raise errors.messages.join ","
      end

      def errors
        rules.errors
      end

      private def load_validations_rules
        {% for name, options in FIELD_OPTIONS %}
          {% for predicate, expected_value in options %}
            {% custom_validator = predicate.id.stringify.split('_').map(&.capitalize).join("") + "Validator" %}
            {% if !["message", "type"].includes?(predicate.stringify) && CUSTOM_VALIDATORS[custom_validator] != nil %}
            rules << {{custom_validator.id}}.new(self, {{options[:message]}} || "")
            {% end %}
          {% end %}

          rules << Schema::Rule.new(:{{name.id}}, {{options[:message]}} || "") do |rule|
          {% for predicate, expected_value in options %}
            {% custom_validator = predicate.id.stringify.split('_').map(&.capitalize).join("") + "Validator" %}
            {% if !["message", "param_type", "type", "inner", "nilable"].includes?(predicate.stringify) && CUSTOM_VALIDATORS[custom_validator] == nil %}
            rule.{{predicate.id}}?(@{{name.id}}, {{expected_value}}) &
            {% end %}
          {% end %}
          {% if options[:inner] %}
          @{{name.id}}.valid?
          {% else %}
          true
          {% end %}
          end
        {% end %}
      end
    end

    # JSON - Use for validating json payload
    macro json(attribute, **options)
      {% FIELD_OPTIONS[attribute.var] = options %}
      {% CONTENT_ATTRIBUTES[attribute.var] = options || {} of Nil => Nil %}
      {% CONTENT_ATTRIBUTES[attribute.var][:type] = attribute.type %}
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :json %}
    end

    # Query - Use for validating query parameters
    macro query(attribute, **options)
      {% FIELD_OPTIONS[attribute.var] = options %}
      {% CONTENT_ATTRIBUTES[attribute.var] = options || {} of Nil => Nil %}
      {% CONTENT_ATTRIBUTES[attribute.var][:type] = attribute.type %}
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :query %}
    end

    # Form - Use for validating form inputs parameters
    macro form(attribute, **options)
      {% FIELD_OPTIONS[attribute.var] = options %}
      {% CONTENT_ATTRIBUTES[attribute.var] = options || {} of Nil => Nil %}
      {% CONTENT_ATTRIBUTES[attribute.var][:type] = attribute.type %}
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :form %}
    end

    # Path - Use for validating path inputs parameters
    macro path(attribute, **options)
      {% FIELD_OPTIONS[attribute.var] = options %}
      {% CONTENT_ATTRIBUTES[attribute.var] = options || {} of Nil => Nil %}
      {% CONTENT_ATTRIBUTES[attribute.var][:type] = attribute.type %}
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :path %}
    end

    private macro __process_params
      {% for name, options in FIELD_OPTIONS %}
        {% type = options[:type] %}
        {% nilable = options[:nilable] != nil ? true : false %}
        {% key = options[:key] != nil ? options[:key] : name.stringify.downcase %}
        @[JSON::Field(emit_null: {{nilable}}, key: {{key}})]
        @[YAML::Field(emit_null: {{nilable}}, key: {{key}})]
        getter {{name}} : {{type}} {% if options[:default] %} = {{options[:default]}} {% end %} 
      {% end %}

      def initialize(params : Params, prefix = "")
        {% for name, options in FIELD_OPTIONS %}
          {% field_type = CONTENT_ATTRIBUTES[name][:type] %}
          {% param_type = CONTENT_ATTRIBUTES[name][:param_type] %}
          {% key = name.id %}
          value = params.{{param_type.id}}[{{key.id.stringify}}]
          key = "#{prefix}{{key.id}}"

          {% if options[:inner] %}
            @{{name.id}} = {{field_type}}.new(params, "#{key}.")
          {% else %}
            {% if field_type.is_a?(Generic) %}
              {% sub_type = field_type.type_vars.uniq %}
              @{{name.id}} = value.as_s.split(",").map do |item|
                Schema::ConvertTo({{sub_type.join("|").id}}).new(item).value
              end.as({{field_type}})
            {% else %}
              @{{name.id}} = Schema::ConvertTo({{field_type}}).new(value).value
            {% end %}
          {% end %}
        {% end %}
      end
    end
  end
end
