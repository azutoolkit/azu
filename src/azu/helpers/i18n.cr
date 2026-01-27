require "yaml"
require "json"

module Azu
  module Helpers
    # Internationalization (i18n) system for template translations.
    #
    # I18n provides a simple and flexible way to internationalize your
    # Azu application with support for:
    #
    # - YAML and JSON translation files
    # - Interpolation with named parameters
    # - Pluralization rules
    # - Date and number localization
    # - Locale detection from requests
    #
    # ## Setup
    #
    # 1. Create locale files in your locales directory:
    #
    # ```yaml
    # # locales/en.yml
    # en:
    #   welcome:
    #     title: "Welcome!"
    #     greeting: "Hello, %{name}!"
    #   users:
    #     count:
    #       zero: "No users"
    #       one: "1 user"
    #       other: "%{count} users"
    # ```
    #
    # 2. Configure I18n in your application:
    #
    # ```
    # Azu::Helpers::I18n.configure do |config|
    #   config.load_path = ["locales"]
    #   config.default_locale = "en"
    #   config.available_locales = ["en", "es", "fr"]
    # end
    # ```
    #
    # ## Template Usage
    #
    # ```jinja
    # {{ t("welcome.title") }}
    # {{ t("welcome.greeting", name=user.name) }}
    # {{ t("users.count", count=users.size) }}
    # ```
    class I18n
      # Configuration for I18n
      class Config
        property load_path : Array(String) = ["locales"]
        property default_locale : String = "en"
        property available_locales : Array(String) = ["en"]
        property fallback_locale : String? = nil
        property? raise_on_missing : Bool = false
        property missing_key_handler : Proc(String, String, String)? = nil
      end

      @@config = Config.new
      @@translations = {} of String => Hash(String, YAML::Any)
      @@loaded = false
      @@mutex = Mutex.new
      @@current_locale : String?
      @@missing_key_format : String?

      # Configure I18n settings.
      #
      # ```
      # Azu::Helpers::I18n.configure do |config|
      #   config.default_locale = "en"
      #   config.load_path = ["locales"]
      # end
      # ```
      def self.configure(&) : Nil
        yield @@config
        reload!
      end

      # Get the configuration.
      def self.config : Config
        @@config
      end

      # Get/set the current locale for the current fiber.
      def self.locale : String
        @@current_locale || @@config.default_locale
      end

      def self.locale=(value : String) : String
        @@current_locale = value
      end

      # Get the default locale.
      def self.default_locale : String
        @@config.default_locale
      end

      def self.default_locale=(value : String) : String
        @@config.default_locale = value
      end

      # Get available locales.
      def self.available_locales : Array(String)
        @@config.available_locales
      end

      # Set load path.
      def self.load_path=(paths : Array(String)) : Nil
        @@config.load_path = paths
        reload!
      end

      # Get fallback locale.
      def self.fallback_locale : String?
        @@config.fallback_locale
      end

      # Set fallback locale.
      def self.fallback_locale=(value : String?) : String?
        @@config.fallback_locale = value
      end

      # Get raise on missing setting.
      def self.raise_on_missing? : Bool
        @@config.raise_on_missing?
      end

      # Set raise on missing.
      def self.raise_on_missing=(value : Bool) : Bool
        @@config.raise_on_missing = value
      end

      # Get missing key format.
      def self.missing_key_format : String
        @@missing_key_format ||= "[missing: %{key}]"
      end

      # Set missing key format.
      def self.missing_key_format=(value : String) : String
        @@missing_key_format = value
      end

      # Load translations from configured paths.
      def self.load_translations : Nil
        reload!
      end

      # Translate a key.
      #
      # ```
      # I18n.t("welcome.title")                    # => "Welcome!"
      # I18n.t("welcome.greeting", name: "John")   # => "Hello, John!"
      # I18n.t("users.count", count: 5)            # => "5 users"
      # I18n.t("missing.key", default: "Fallback") # => "Fallback"
      # ```
      def self.t(
        key : String,
        locale : String? = nil,
        default : String? = nil,
        count : Int32? = nil,
        **options,
      ) : String
        # Convert named tuple to hash for internal processing
        opts = {} of String => String
        options.each { |k, v| opts[k.to_s] = v.to_s }
        translate(key, locale, default, count, opts)
      end

      # Translate a key with explicit interpolation hash.
      # Used internally and by template helpers.
      def self.t(
        key : String,
        default : String?,
        count : Int32?,
        interpolations : Hash(String, String),
      ) : String
        translate(key, nil, default, count, interpolations)
      end

      # Internal translation method.
      private def self.translate(
        key : String,
        locale : String?,
        default : String?,
        count : Int32?,
        interpolations : Hash(String, String),
      ) : String
        ensure_loaded!

        locale ||= self.locale
        translation = lookup(key, locale)

        # Handle missing translation
        if translation.nil?
          return handle_missing(key, locale, default)
        end

        # Handle pluralization
        if count && translation.is_a?(YAML::Any) && translation.as_h?
          translation = pluralize(translation, count)
        end

        # Convert to string and interpolate
        result = translation.to_s

        # Interpolate count
        if count
          result = result.gsub("%{count}", count.to_s)
        end

        # Interpolate other options
        interpolations.each do |name, value|
          result = result.gsub("%{#{name}}", value)
        end

        result
      end

      # Localize a date or number.
      #
      # ```
      # I18n.l(Time.utc, format: "date.short") # => "Jan 15"
      # I18n.l(Time.utc, format: "date.long")  # => "January 15, 2024"
      # ```
      def self.l(
        value : Time,
        format : String = "date.default",
        locale : String? = nil,
      ) : String
        ensure_loaded!

        locale ||= self.locale
        format_string = lookup(format, locale)

        if format_string
          value.to_s(format_string.to_s)
        else
          # Default formats
          case format
          when "date.short"
            value.to_s("%b %d")
          when "date.long"
            value.to_s("%B %d, %Y")
          when "time.short"
            value.to_s("%H:%M")
          when "time.long"
            value.to_s("%H:%M:%S")
          when "datetime.short"
            value.to_s("%b %d %H:%M")
          when "datetime.long"
            value.to_s("%B %d, %Y %H:%M:%S")
          else
            value.to_s("%Y-%m-%d %H:%M:%S")
          end
        end
      end

      # Check if a key exists.
      def self.exists?(key : String, locale : String? = nil) : Bool
        ensure_loaded!
        locale ||= self.locale
        !lookup(key, locale).nil?
      end

      # Get the display name for a locale.
      #
      # ```
      # I18n.locale_name("en") # => "English"
      # I18n.locale_name("es") # => "Spanish"
      # ```
      def self.locale_name(locale : String) : String
        LOCALE_NAMES[locale]? || locale.upcase
      end

      # Reload translations from files.
      def self.reload! : Nil
        @@mutex.synchronize do
          @@translations.clear
          @@loaded = false
        end
        ensure_loaded!
      end

      # Reset I18n state.
      def self.reset! : Nil
        @@mutex.synchronize do
          @@config = Config.new
          @@translations.clear
          @@loaded = false
          @@current_locale = nil
        end
      end

      # Execute a block with a specific locale.
      def self.with_locale(locale : String, &)
        previous = @@current_locale
        @@current_locale = locale
        begin
          yield
        ensure
          @@current_locale = previous
        end
      end

      private def self.ensure_loaded! : Nil
        return if @@loaded

        @@mutex.synchronize do
          return if @@loaded
          load_translations!
          @@loaded = true
        end
      end

      private def self.load_translations! : Nil
        @@config.load_path.each do |path|
          next unless Dir.exists?(path)

          Dir.glob(File.join(path, "**", "*.{yml,yaml,json}")).each do |file_path|
            load_file(file_path)
          end
        end
      end

      private def self.load_file(path : String) : Nil
        content = File.read(path)

        data = if path.ends_with?(".json")
                 JSON.parse(content)
               else
                 YAML.parse(content)
               end

        data.as_h.each do |locale, translations|
          locale_key = locale.to_s
          @@translations[locale_key] ||= {} of String => YAML::Any

          flatten_translations(translations, "") do |key, value|
            @@translations[locale_key][key] = value
          end
        end
      rescue ex
        Log.for("Azu::I18n").warn(exception: ex) { "Failed to load translation file: #{path}" }
      end

      private def self.flatten_translations(
        data,
        prefix : String,
        &block : String, YAML::Any ->
      ) : Nil
        case data
        when YAML::Any
          if hash = data.as_h?
            # Check if this is a pluralization hash (has zero, one, or other keys)
            if pluralization_hash?(hash)
              yield prefix, data
            else
              hash.each do |key, value|
                new_prefix = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
                flatten_translations(value, new_prefix, &block)
              end
            end
          else
            yield prefix, data
          end
        when JSON::Any
          if hash = data.as_h?
            # Check if this is a pluralization hash
            if hash.has_key?("zero") || hash.has_key?("one") || hash.has_key?("other")
              yield prefix, YAML.parse(data.to_json)
            else
              hash.each do |key, value|
                new_prefix = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
                flatten_translations(YAML.parse(value.to_json), new_prefix, &block)
              end
            end
          else
            yield prefix, YAML.parse(data.to_json)
          end
        end
      end

      # Check if a YAML hash is a pluralization structure
      private def self.pluralization_hash?(hash : Hash(YAML::Any, YAML::Any)) : Bool
        keys = hash.keys.map(&.to_s)
        # It's a pluralization hash if it has zero, one, or other as keys
        # and all values are strings (not nested hashes)
        return false if keys.empty?

        plural_keys = ["zero", "one", "two", "few", "many", "other"]
        has_plural_key = keys.any? { |k| plural_keys.includes?(k) }

        return false unless has_plural_key

        # Ensure all values are scalar (not nested hashes)
        hash.values.all? { |v| !v.as_h? }
      end

      private def self.lookup(key : String, locale : String) : YAML::Any?
        # Try exact locale
        if translations = @@translations[locale]?
          if value = translations[key]?
            return value
          end
        end

        # Try fallback locale
        if fallback = @@config.fallback_locale
          if translations = @@translations[fallback]?
            if value = translations[key]?
              return value
            end
          end
        end

        # Try default locale
        if locale != @@config.default_locale
          if translations = @@translations[@@config.default_locale]?
            return translations[key]?
          end
        end

        nil
      end

      private def self.pluralize(translation : YAML::Any, count : Int32) : String
        hash = translation.as_h

        key = case count
              when 0
                hash["zero"]? ? "zero" : "other"
              when 1
                "one"
              else
                "other"
              end

        if value = hash[key]?
          value.to_s
        elsif value = hash["other"]?
          value.to_s
        else
          translation.to_s
        end
      end

      private def self.handle_missing(key : String, locale : String, default : String?) : String
        if default
          return default
        end

        if handler = @@config.missing_key_handler
          return handler.call(key, locale)
        end

        if @@config.raise_on_missing?
          raise "Missing translation: #{key} for locale #{locale}"
        end

        # Return key with markers for debugging
        "[missing: #{key}]"
      end

      # Common locale display names
      LOCALE_NAMES = {
        "en"    => "English",
        "es"    => "Spanish",
        "fr"    => "French",
        "de"    => "German",
        "it"    => "Italian",
        "pt"    => "Portuguese",
        "zh"    => "Chinese",
        "ja"    => "Japanese",
        "ko"    => "Korean",
        "ar"    => "Arabic",
        "ru"    => "Russian",
        "nl"    => "Dutch",
        "sv"    => "Swedish",
        "pl"    => "Polish",
        "tr"    => "Turkish",
        "th"    => "Thai",
        "vi"    => "Vietnamese",
        "id"    => "Indonesian",
        "hi"    => "Hindi",
        "he"    => "Hebrew",
        "en-US" => "English (US)",
        "en-GB" => "English (UK)",
        "es-ES" => "Spanish (Spain)",
        "es-MX" => "Spanish (Mexico)",
        "pt-BR" => "Portuguese (Brazil)",
        "pt-PT" => "Portuguese (Portugal)",
        "zh-CN" => "Chinese (Simplified)",
        "zh-TW" => "Chinese (Traditional)",
      }
    end
  end
end
