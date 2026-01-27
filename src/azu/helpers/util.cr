require "crinja"
require "html"
require "uri"

module Azu
  module Helpers
    # Utility functions for template helpers.
    #
    # These methods provide common functionality used across multiple
    # helper categories like HTML generation, number formatting, and
    # string manipulation.
    module Util
      extend self

      # Escapes HTML special characters.
      #
      # ```
      # Util.escape_html("<script>alert('xss')</script>")
      # # => "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      # ```
      def escape_html(text : String) : String
        HTML.escape(text)
      end

      # Formats a number with thousands delimiter.
      #
      # ```
      # Util.number_with_delimiter(1234567)      # => "1,234,567"
      # Util.number_with_delimiter(1234.56)      # => "1,234.56"
      # Util.number_with_delimiter(1234567, ".") # => "1.234.567"
      # ```
      def number_with_delimiter(
        number : Number,
        delimiter : String = ",",
        separator : String = ".",
      ) : String
        # Handle negative numbers
        negative = number < 0
        number = number.abs

        # Split into integer and decimal parts
        str = number.to_s
        parts = str.split(".")
        integer_part = parts[0]
        decimal_part = parts[1]?

        # Add delimiters to integer part
        formatted_integer = integer_part.reverse.gsub(/(\d{3})(?=\d)/, "\\1#{delimiter}").reverse

        # Combine parts
        result = if decimal_part
                   "#{formatted_integer}#{separator}#{decimal_part}"
                 else
                   formatted_integer
                 end

        negative ? "-#{result}" : result
      end

      # Formats a number as currency.
      #
      # ```
      # Util.currency(1234.5)                 # => "$1,234.50"
      # Util.currency(1234.5, symbol: "€")    # => "€1,234.50"
      # Util.currency(1234.567, precision: 3) # => "$1,234.567"
      # ```
      def currency(
        number : Number,
        symbol : String = "$",
        precision : Int32 = 2,
        delimiter : String = ",",
        separator : String = ".",
      ) : String
        formatted = "%.#{precision}f" % number.abs
        parts = formatted.split(".")
        integer_part = parts[0].to_i64
        decimal_part = parts[1]?

        formatted_integer = number_with_delimiter(integer_part, delimiter, separator)

        result = if decimal_part && precision > 0
                   "#{formatted_integer}#{separator}#{decimal_part}"
                 else
                   formatted_integer
                 end

        negative = number < 0
        if negative
          "-#{symbol}#{result}"
        else
          "#{symbol}#{result}"
        end
      end

      # Formats a number as a percentage.
      #
      # ```
      # Util.percentage(0.756)               # => "76%"
      # Util.percentage(0.756, precision: 1) # => "75.6%"
      # ```
      def percentage(number : Number, precision : Int32 = 0) : String
        value = (number * 100).round(precision)
        if precision > 0
          "%.#{precision}f%%" % value
        else
          "#{value.to_i}%"
        end
      end

      # Formats bytes as human-readable file size.
      #
      # ```
      # Util.filesize(1024)       # => "1 KB"
      # Util.filesize(1048576)    # => "1 MB"
      # Util.filesize(1073741824) # => "1 GB"
      # ```
      def filesize(bytes : Number, precision : Int32 = 1) : String
        units = ["B", "KB", "MB", "GB", "TB", "PB"]
        size = bytes.to_f
        unit_index = 0

        while size >= 1024 && unit_index < units.size - 1
          size /= 1024
          unit_index += 1
        end

        if unit_index == 0
          "#{size.to_i} #{units[unit_index]}"
        else
          "%.#{precision}f #{units[unit_index]}" % size
        end
      end

      # Truncates a string to the specified length.
      #
      # ```
      # Util.truncate("Hello World", 8)      # => "Hello..."
      # Util.truncate("Hello", 10)           # => "Hello"
      # Util.truncate("Hello World", 8, "…") # => "Hello W…"
      # ```
      def truncate(text : String, length : Int32 = 100, omission : String = "...") : String
        return text if text.size <= length

        stop = length - omission.size
        stop = 0 if stop < 0

        text[0, stop] + omission
      end

      # Truncates HTML while preserving tag structure.
      #
      # This is a simplified implementation that tries to keep tags balanced.
      #
      # ```
      # Util.truncate_html("<p>Hello <b>World</b></p>", 10)
      # # => "<p>Hello <b>W...</b></p>"
      # ```
      def truncate_html(html : String, length : Int32 = 100, omission : String = "...") : String
        # Simple approach: strip tags, truncate, then we lose formatting
        # For a more robust solution, we'd need a full HTML parser
        text_content = strip_tags(html)

        return html if text_content.size <= length

        # For now, do simple truncation
        # TODO: Implement proper HTML-aware truncation
        truncate(text_content, length, omission)
      end

      # Strips HTML tags from a string.
      #
      # ```
      # Util.strip_tags("<p>Hello <b>World</b></p>") # => "Hello World"
      # ```
      def strip_tags(html : String) : String
        html.gsub(/<[^>]+>/, "")
      end

      # Converts newlines to HTML line breaks.
      #
      # ```
      # Util.simple_format("Hello\nWorld") # => "Hello<br>World"
      # ```
      def simple_format(text : String) : String
        escaped = escape_html(text)
        escaped.gsub(/\r?\n/, "<br>")
      end

      # Highlights occurrences of a phrase in text.
      #
      # ```
      # Util.highlight("Hello World", "World")
      # # => "Hello <mark>World</mark>"
      # ```
      def highlight(
        text : String,
        phrase : String,
        highlighter : String = "<mark>\\0</mark>",
      ) : String
        return text if phrase.empty?

        escaped_phrase = Regex.escape(phrase)
        text.gsub(/#{escaped_phrase}/i, highlighter)
      end

      # Pluralizes a word based on count.
      #
      # ```
      # Util.pluralize(1, "item")             # => "item"
      # Util.pluralize(2, "item")             # => "items"
      # Util.pluralize(2, "person", "people") # => "people"
      # ```
      def pluralize(count : Number, singular : String, plural : String? = nil) : String
        plural ||= "#{singular}s"
        count == 1 ? singular : plural
      end

      # Generates a URL-safe slug from text.
      #
      # ```
      # Util.slugify("Hello World!") # => "hello-world"
      # ```
      def slugify(text : String) : String
        text
          .downcase
          .gsub(/[^a-z0-9\s-]/, "")
          .gsub(/[\s_]+/, "-")
          .gsub(/-+/, "-")
          .strip("-")
      end

      # Converts underscored/camelCase to human-readable text.
      #
      # ```
      # Util.humanize("user_name") # => "User name"
      # Util.humanize("firstName") # => "First name"
      # ```
      def humanize(text : String) : String
        text
          .gsub(/_/, " ")
          .gsub(/([a-z])([A-Z])/, "\\1 \\2")
          .capitalize
      end

      # Title-cases a string.
      #
      # ```
      # Util.titleize("hello world") # => "Hello World"
      # ```
      def titleize(text : String) : String
        text.split.map(&.capitalize).join(" ")
      end

      # Builds HTML attributes string from a hash.
      #
      # ```
      # Util.tag_attributes({class: "btn", id: "submit"})
      # # => "class=\"btn\" id=\"submit\""
      # ```
      def tag_attributes(attrs : Hash(String, String)) : String
        attrs.compact_map do |key, value|
          if value == "true" || value == true.to_s
            key.to_s
          elsif value == "false" || value == false.to_s
            nil
          else
            "#{key}=\"#{escape_html(value.to_s)}\""
          end
        end.join(" ")
      end

      # Builds an HTML tag.
      #
      # ```
      # Util.tag("input", {type: "text", name: "email"})
      # # => "<input type=\"text\" name=\"email\" />"
      #
      # Util.tag("div", {class: "container"}, "Content")
      # # => "<div class=\"container\">Content</div>"
      # ```
      def tag(
        name : String,
        attrs : Hash(String, String) = {} of String => String,
        content : String? = nil,
        self_closing : Bool = false,
      ) : String
        attr_str = tag_attributes(attrs)
        attr_part = attr_str.empty? ? "" : " #{attr_str}"

        if self_closing
          "<#{name}#{attr_part} />"
        elsif content
          "<#{name}#{attr_part}>#{content}</#{name}>"
        else
          "<#{name}#{attr_part}></#{name}>"
        end
      end

      # Builds a self-closing HTML tag.
      #
      # ```
      # Util.void_tag("input", {type: "text"})
      # # => "<input type=\"text\" />"
      # ```
      def void_tag(name : String, attrs : Hash(String, String) = {} of String => String) : String
        tag(name, attrs, nil, self_closing: true)
      end

      # URL-encodes a string.
      #
      # ```
      # Util.url_encode("hello world") # => "hello%20world"
      # ```
      def url_encode(text : String) : String
        URI.encode_www_form(text)
      end

      # Builds HTML attributes string from Crinja arguments.
      #
      # This method extracts attribute values from Crinja function arguments
      # and builds an HTML attribute string, excluding specified keys.
      #
      # ```
      # # In a Crinja function:
      # attrs = Util.build_html_attributes_from_crinja(arguments, ["text", "id"])
      # # => " class=\"btn\" target=\"_blank\""
      # ```
      def build_html_attributes_from_crinja(
        args : Crinja::Arguments,
        exclude : Array(String) = [] of String,
      ) : String
        result = String::Builder.new

        args.defaults.each_key do |key|
          key_str = key.to_s
          next if exclude.includes?(key_str)

          value = args[key_str]
          next if value.none? || value.undefined?

          # Handle boolean attributes
          if value.truthy? && (value.raw.is_a?(Bool) || value.to_s == "true")
            result << %( #{key_str})
          elsif !value.to_s.empty? && value.to_s != "false"
            result << %( #{key_str}="#{escape_html(value.to_s)}")
          end
        end

        result.to_s
      end

      # Parses a time value from various formats.
      #
      # ```
      # Util.parse_time(Time.utc)     # => Time
      # Util.parse_time("2024-01-15") # => Time
      # Util.parse_time(1705276800)   # => Time (from unix timestamp)
      # ```
      def parse_time(value) : Time
        case value
        when Time
          value
        when Int32, Int64
          Time.unix(value.to_i64)
        when String
          if value =~ /^\d+$/
            Time.unix(value.to_i64)
          else
            begin
              Time.parse(value, "%Y-%m-%d", Time::Location::UTC)
            rescue
              begin
                Time.parse(value, "%Y-%m-%dT%H:%M:%S", Time::Location::UTC)
              rescue
                Time.utc
              end
            end
          end
        else
          Time.utc
        end
      end
    end
  end
end
