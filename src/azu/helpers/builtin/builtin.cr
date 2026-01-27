require "./form_helpers"
require "./asset_helpers"
require "./url_helpers"
require "./component_helpers"
require "./date_helpers"
require "./number_helpers"
require "./html_helpers"

module Azu
  module Helpers
    # Built-in template helpers for common web development tasks.
    #
    # These helpers are automatically registered when Azu starts and
    # are available in all templates.
    #
    # ## Categories
    #
    # - **Form Helpers**: Build forms with CSRF protection and inputs
    # - **Asset Helpers**: Include CSS, JS, images with fingerprinting
    # - **URL Helpers**: Generate links, buttons, and navigation
    # - **Component Helpers**: Integrate Spark live components
    # - **Date Helpers**: Format dates and times
    # - **Number Helpers**: Format numbers and currency
    # - **HTML Helpers**: Safe HTML output and text manipulation
    module Builtin
      # Register all built-in helpers.
      #
      # This is called automatically during Azu initialization.
      def self.register_all : Nil
        FormHelpers.register
        AssetHelpers.register
        UrlHelpers.register
        ComponentHelpers.register
        DateHelpers.register
        NumberHelpers.register
        HtmlHelpers.register
        register_i18n_helpers
      end

      # Register i18n helpers.
      private def self.register_i18n_helpers : Nil
        # t() - Translation function
        t_func = Crinja.function({
          key:     "",
          default: nil,
          count:   nil,
        }, :t) do
          key = arguments["key"].to_s

          # Get additional arguments for interpolation
          interpolations = {} of String => String
          arguments.kwargs.each do |k, v|
            next if k.in?("key", "default", "count")
            interpolations[k] = v.to_s
          end

          default_val = arguments["default"]
          default_str = default_val.none? ? nil : default_val.to_s

          count_val = arguments["count"]
          count_int = count_val.none? ? nil : count_val.to_i

          I18n.t(key, default_str, count_int, interpolations)
        end
        Registry.register_function(:t, t_func)

        # l() - Localization filter
        l_filter = Crinja.filter({format: "date.default"}, :l) do
          time = Util.parse_time(target.raw)
          format = arguments["format"].to_s
          I18n.l(time, format: format)
        end
        Registry.register_filter(:l, l_filter)

        # current_locale() - Get current locale
        locale_func = Crinja.function(:current_locale) do
          I18n.locale
        end
        Registry.register_function(:current_locale, locale_func)

        # available_locales() - Get available locales
        locales_func = Crinja.function(:available_locales) do
          I18n.available_locales
        end
        Registry.register_function(:available_locales, locales_func)

        # locale_name filter - Get display name for locale
        locale_name_filter = Crinja.filter(:locale_name) do
          I18n.locale_name(target.to_s)
        end
        Registry.register_filter(:locale_name, locale_name_filter)

        # pluralize function
        pluralize_func = Crinja.function({
          count:    0,
          singular: "",
          plural:   nil,
        }, :pluralize) do
          count = arguments["count"].to_i
          singular = arguments["singular"].to_s
          plural_val = arguments["plural"]
          plural = plural_val.none? ? nil : plural_val.to_s

          Util.pluralize(count, singular, plural)
        end
        Registry.register_function(:pluralize, pluralize_func)
      end
    end
  end
end
