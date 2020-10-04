require "schema"

module Azu
  # Design By Contract (DbC) is a software correctness methodology. It uses preconditions and postconditions to
  # document (or programmatically assert) the change in state caused by a piece of a program.
  # Design by Contract is a trademarked term of BertrandMeyer and implemented in his EiffelLanguage as assertions.
  #
  # Azu Contracts borrows this concept and uses it to provide a consice way to validate objects.
  #
  # Azu Contract benefits:
  #
  # * Automatic, high-quality documentation.
  # * Type safe request parameters
  # * Built-in framework for focused and effective testing.
  # * The ability to communicate your design without having to describe the details of the implementation.
  # * A clear, simple guide throughout the entire software development process.
  # * (for managers) a direct handle on the state of their projects.
  #
  # Azu contracts are implemented by the [Schema](https://github.com/eliasjpr/schema) shard
  #
  # ### Example Use:
  #
  # ```
  # class UserRequest
  #   include Azu::Request
  #   include Azu::Contract
  #
  #   query name : String, message: "Param name must be present.", presence: true
  # end
  # ```
  #
  # ### Initializers
  #
  # ```
  # UserRequest.from_json(pyaload: String)
  # UserRequest.from_yaml(pyaload: String)
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
  module Contract
    macro included
      CONTENT_ATTRIBUTES = {} of Nil => Nil
      FIELD_OPTIONS = {} of Nil => Nil

      macro finished
        __process_params
      end

      include Schema::Validation
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
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :query %}
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
        {% key = options[:key] != nil ? options[:key] : name.downcase.stringify %}
        @[JSON::Field(emit_null: {{nilable}}, key: {{key}})]
        @[YAML::Field(emit_null: {{nilable}}, key: {{key}})]
        getter {{name}} : {{type}}
      {% end %}

      def initialize(@context : HTTP::Server::Context, prefix = "")
        @params = Params.new @context.request

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
              {% sub_type = field_type.type_vars %}
              @{{name.id}} = value.split(",").map do |item|
                Schema::ConvertTo({{sub_type.join('|').id}}).new(item).value
              end
            {% else %}
              @{{name.id}} = Schema::ConvertTo({{field_type}}).new(value).value
            {% end %}
          {% end %}
        {% end %}
      end
    end
  end
end
