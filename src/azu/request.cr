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
  module Request
    macro included
      CONTENT_ATTRIBUTES = {} of Nil => Nil
      FIELD_OPTIONS = {} of Nil => Nil
      
      macro finished
        __process_params
        include JSON::Serializable
        include Schema::Validation
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
        {% key = options[:key] != nil ? options[:key] : name.downcase.stringify %}
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
