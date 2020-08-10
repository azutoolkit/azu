require "schema"

module Azu
  module Contract
    macro included
      CONTENT_ATTRIBUTES = {} of Nil => Nil
      FIELD_OPTIONS = {} of Nil => Nil

      macro finished
        __process_params
      end

      include Schema::Validation
    end

    macro query(attribute, **options)
      {% FIELD_OPTIONS[attribute.var] = options %}
      {% CONTENT_ATTRIBUTES[attribute.var] = options || {} of Nil => Nil %}
      {% CONTENT_ATTRIBUTES[attribute.var][:type] = attribute.type %}
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :query %}
    end

    macro form(attribute, **options)
      {% FIELD_OPTIONS[attribute.var] = options %}
      {% CONTENT_ATTRIBUTES[attribute.var] = options || {} of Nil => Nil %}
      {% CONTENT_ATTRIBUTES[attribute.var][:type] = attribute.type %}
      {% CONTENT_ATTRIBUTES[attribute.var][:param_type] = :query %}
    end

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
