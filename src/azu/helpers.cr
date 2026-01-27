require "crinja"
require "./helpers/registry"
require "./helpers/context"
require "./helpers/util"
require "./helpers/i18n"
require "./helpers/builtin/builtin"

module Azu
  # Template helpers provide a powerful DSL for extending Crinja templates
  # with custom filters, functions, and global variables.
  #
  # ## Quick Start
  #
  # ```
  # # Define a custom filter
  # Azu::Helpers.filter :shout do
  #   target.to_s.upcase + "!"
  # end
  #
  # # Define a function with arguments
  # Azu::Helpers.function({name: "World"}, :greet) do
  #   "Hello, #{arguments["name"]}!"
  # end
  #
  # # Define a global variable
  # Azu::Helpers.global :app_name, "My Application"
  # ```
  #
  # ## Template Usage
  #
  # ```jinja
  # {{ "hello" | shout }}      {# HELLO! #}
  # {{ greet(name="Alice") }}  {# Hello, Alice! #}
  # {{ app_name }}             {# My Application #}
  # ```
  module Helpers
    VERSION = "1.0.0"

    # Registers a custom Crinja filter.
    #
    # Filters transform values using the pipe syntax: `{{ value | filter_name }}`.
    #
    # ## Simple Filter
    #
    # ```
    # Azu::Helpers.filter :uppercase do
    #   target.to_s.upcase
    # end
    # ```
    #
    # ## Filter with Arguments
    #
    # ```
    # Azu::Helpers.filter({precision: 2}, :round_number) do
    #   target.to_f.round(arguments["precision"].to_i)
    # end
    # ```
    #
    # Inside the block, you have access to:
    # - `target` - The value being filtered
    # - `arguments` - Named arguments passed to the filter
    # - `env` - The Crinja environment
    macro filter(defaults = nil, name = nil, &block)
      {% if defaults.is_a?(SymbolLiteral) || defaults.is_a?(StringLiteral) %}
        {% actual_name = defaults %}
        {% actual_defaults = nil %}
      {% else %}
        {% actual_name = name %}
        {% actual_defaults = defaults %}
      {% end %}

      %filter = Crinja.filter({{ actual_defaults }}, {{ actual_name }}) {{ block }}
      Azu::Helpers::Registry.register_filter({{ actual_name }}, %filter)
    end

    # Registers a custom Crinja function.
    #
    # Functions are called directly in templates: `{{ function_name(args) }}`.
    #
    # ## Simple Function
    #
    # ```
    # Azu::Helpers.function :current_year do
    #   Time.utc.year.to_s
    # end
    # ```
    #
    # ## Function with Arguments
    #
    # ```
    # Azu::Helpers.function({name: "World"}, :greet) do
    #   "Hello, #{arguments["name"]}!"
    # end
    # ```
    #
    # Inside the block, you have access to:
    # - `arguments` - Named arguments passed to the function
    # - `env` - The Crinja environment
    macro function(defaults = nil, name = nil, &block)
      {% if defaults.is_a?(SymbolLiteral) || defaults.is_a?(StringLiteral) %}
        {% actual_name = defaults %}
        {% actual_defaults = nil %}
      {% else %}
        {% actual_name = name %}
        {% actual_defaults = defaults %}
      {% end %}

      %function = Crinja.function({{ actual_defaults }}, {{ actual_name }}) {{ block }}
      Azu::Helpers::Registry.register_function({{ actual_name }}, %function)
    end

    # Registers a global template variable.
    #
    # Global variables are accessible directly in templates.
    #
    # ```
    # Azu::Helpers.global :app_name, "My Application"
    # Azu::Helpers.global :version, "1.0.0"
    # ```
    #
    # In templates:
    #
    # ```jinja
    # <title>{{ app_name }} v{{ version }}</title>
    # ```
    macro global(name, value)
      Azu::Helpers::Registry.register_global({{ name }}, {{ value }})
    end

    # Registers a Crinja test.
    #
    # Tests are used with `is` syntax: `{% if value is test_name %}`.
    #
    # ```
    # Azu::Helpers.test :blank do
    #   target.to_s.blank?
    # end
    # ```
    #
    # In templates:
    #
    # ```jinja
    # {% if name is blank %}
    #   <p>No name provided</p>
    # {% endif %}
    # ```
    macro test(defaults = nil, name = nil, &block)
      {% if defaults.is_a?(SymbolLiteral) || defaults.is_a?(StringLiteral) %}
        {% actual_name = defaults %}
        {% actual_defaults = nil %}
      {% else %}
        {% actual_name = name %}
        {% actual_defaults = defaults %}
      {% end %}

      %test = Crinja.test({{ actual_defaults }}, {{ actual_name }}) {{ block }}
      Azu::Helpers::Registry.register_test({{ actual_name }}, %test)
    end

    # Initialize and register all built-in helpers.
    #
    # This is automatically called when Azu starts, but can be called
    # manually if needed.
    def self.initialize!
      Builtin.register_all
    end

    # Reset all registered helpers.
    #
    # Useful for testing.
    def self.reset!
      Registry.reset!
    end
  end
end
