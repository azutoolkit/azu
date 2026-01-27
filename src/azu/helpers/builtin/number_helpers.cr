module Azu
  module Helpers
    module Builtin
      # Number helpers for formatting numeric values.
      #
      # ## Example
      #
      # ```jinja
      # <p>Price: {{ product.price | currency("$") }}</p>
      # <p>Views: {{ post.views | number_with_delimiter }}</p>
      # <p>Discount: {{ discount | percentage(1) }}</p>
      # <p>Size: {{ file.size | filesize }}</p>
      # ```
      module NumberHelpers
        def self.register : Nil
          register_currency
          register_number_with_delimiter
          register_percentage
          register_filesize
          register_ordinal
          register_number_to_human
        end

        private def self.register_currency : Nil
          filter = Crinja.filter({
            symbol:    "$",
            precision: 2,
            delimiter: ",",
            separator: ".",
            format:    "%s%n",
          }, :currency) do
            number = target.to_f rescue 0.0
            symbol = arguments["symbol"].to_s
            precision = arguments["precision"].to_i
            delimiter = arguments["delimiter"].to_s
            separator = arguments["separator"].to_s
            format = arguments["format"].to_s

            formatted = Util.currency(number.abs, "", precision, delimiter, separator)

            # Apply format (%s = symbol, %n = number)
            result = format.gsub("%s", symbol).gsub("%n", formatted)

            # Handle negative numbers
            number < 0 ? "-#{result}" : result
          end
          Registry.register_filter(:currency, filter)
        end

        private def self.register_number_with_delimiter : Nil
          filter = Crinja.filter({
            delimiter: ",",
            separator: ".",
          }, :number_with_delimiter) do
            number = target.to_f rescue 0.0
            delimiter = arguments["delimiter"].to_s
            separator = arguments["separator"].to_s

            Util.number_with_delimiter(number, delimiter, separator)
          end
          Registry.register_filter(:number_with_delimiter, filter)
        end

        private def self.register_percentage : Nil
          filter = Crinja.filter({
            precision: 0,
            format:    "%n%",
          }, :percentage) do
            number = target.to_f rescue 0.0
            precision = arguments["precision"].to_i
            format = arguments["format"].to_s

            value = (number * 100).round(precision)
            formatted = if precision > 0
                          "%.#{precision}f" % value
                        else
                          value.to_i.to_s
                        end

            format.gsub("%n", formatted)
          end
          Registry.register_filter(:percentage, filter)
        end

        private def self.register_filesize : Nil
          filter = Crinja.filter({
            precision: 1,
            binary:    false,
          }, :filesize) do
            bytes = (target.to_i rescue 0).to_i64
            precision = arguments["precision"].to_i
            # Note: binary parameter reserved for future use (binary vs decimal units)

            Util.filesize(bytes, precision)
          end
          Registry.register_filter(:filesize, filter)
        end

        private def self.register_ordinal : Nil
          filter = Crinja.filter(:ordinal) do
            number = target.to_i rescue 0

            suffix = case number.abs % 100
                     when 11, 12, 13
                       "th"
                     else
                       case number.abs % 10
                       when 1 then "st"
                       when 2 then "nd"
                       when 3 then "rd"
                       else        "th"
                       end
                     end

            "#{number}#{suffix}"
          end
          Registry.register_filter(:ordinal, filter)
        end

        private def self.register_number_to_human : Nil
          filter = Crinja.filter({
            precision: 1,
            units:     nil,
          }, :number_to_human) do
            number = target.to_f rescue 0.0
            precision = arguments["precision"].to_i

            abs_number = number.abs

            unit, value = case
                          when abs_number >= 1_000_000_000_000
                            {"trillion", abs_number / 1_000_000_000_000}
                          when abs_number >= 1_000_000_000
                            {"billion", abs_number / 1_000_000_000}
                          when abs_number >= 1_000_000
                            {"million", abs_number / 1_000_000}
                          when abs_number >= 1_000
                            {"thousand", abs_number / 1_000}
                          else
                            {"", abs_number}
                          end

            formatted = if precision > 0 && unit != ""
                          "%.#{precision}f" % value
                        else
                          value.to_i.to_s
                        end

            # Remove trailing zeros
            if formatted.includes?(".")
              formatted = formatted.rstrip('0').rstrip('.')
            end

            result = unit.empty? ? formatted : "#{formatted} #{unit}"
            number < 0 ? "-#{result}" : result
          end
          Registry.register_filter(:number_to_human, filter)
        end
      end
    end
  end
end
