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

      # What an HTML attribute name may be (a name that is not one could end the tag or start another attribute).
      ATTRIBUTE_NAME = /\A[a-zA-Z_:][-a-zA-Z0-9_:.]*\z/

      # What a tag name may be.
      TAG_NAME = /\A[a-zA-Z][a-zA-Z0-9-]*\z/

      # Escapes text for the inside of a JavaScript string literal written in an HTML attribute
      # (`onclick="return confirm('...')"`). HTML decodes entities before JavaScript runs, so HTML escaping alone
      # does not keep a quote inside the string; every character that can end the string, the attribute or a script
      # becomes a `\uXXXX` escape. Plain text is unchanged. Escape the result for HTML as well.
      def js_string_escape(text : String) : String
        text.gsub(/[\\'"<>&\/`\x00-\x1f\x{2028}\x{2029}]/) { |char| "\\u%04x" % char[0].ord }
      end

      # The schemes a link or form may point to; anything else (javascript:, data:, vbscript:, ...) is replaced.
      SAFE_URL_SCHEMES = {"http", "https", "mailto", "tel"}

      private URL_SCHEME = /\A([a-zA-Z][a-zA-Z0-9+.\-]*):/

      # Returns `url` when it is safe to put into `href` or `action`: http, https, mailto, tel, a relative path
      # or a fragment (compared case-insensitively). Any other scheme gives `fallback`. Browsers ignore control
      # characters, spaces and tabs or newlines inside a scheme (`java\tscript:`), so they are removed before the
      # scheme is read. Entities are not decoded here: the value is escaped when it is written, so `&#106;avascript:`
      # reaches the page as text. The result still has to be escaped as an attribute value.
      #
      # ```
      # Util.safe_url("/posts?page=2")                     # => "/posts?page=2"
      # Util.safe_url("JavaScript:alert(1)")               # => "#"
      # Util.safe_url("data:text/html,x", "about:invalid") # => "about:invalid"
      # ```
      def safe_url(url : String, fallback : String = "#") : String
        compact = url.gsub(/[\x00-\x20\x7f]/, "")
        scheme = URL_SCHEME.match(compact).try(&.[1])
        return url if scheme.nil? || SAFE_URL_SCHEMES.includes?(scheme.downcase)
        fallback
      end

      # The hidden `_csrf` field of a form a template renders, holding the render's `csrf_token` (the request's
      # token, see `Handler::CSRF`); an empty string when the render has none.
      def csrf_input(env : Crinja) : String
        value = env.context["csrf_token"]
        return "" if value.none? || value.undefined?
        %(<input type="hidden" name="_csrf" value="#{escape_html(value.to_s)}" />)
      end

      def attribute_name?(name : String) : Bool
        ATTRIBUTE_NAME.matches?(name)
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

      # Highlights occurrences of a phrase in text. Neither `text` nor `phrase` is escaped: the result is only
      # safe as HTML when `text` is. Use `highlight_html` for text that is not.
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

      # Highlights occurrences of a phrase in plain text and returns HTML: the text between the matches and the
      # matches themselves are escaped, `highlighter` (markup written by the template author, `\\0` is the match)
      # is not. The phrase is searched in the raw text, so `&` and `<` match and an entity is never cut in half.
      #
      # ```
      # Util.highlight_html("a <b> c", "<b>") # => "a <mark>&lt;b&gt;</mark> c"
      # ```
      def highlight_html(
        text : String,
        phrase : String,
        highlighter : String = "<mark>\\0</mark>",
      ) : String
        return escape_html(text) if phrase.empty?

        pattern = /#{Regex.escape(phrase)}/i
        String.build do |io|
          position = 0
          text.scan(pattern) do |match|
            io << escape_html(text.byte_slice(position, match.byte_begin - position))
            io << highlighter.gsub("\\0") { escape_html(match[0]) }
            position = match.byte_end
          end
          io << escape_html(text.byte_slice(position))
        end
      end

      private URLIZE_PATTERN = /(?:https?:\/\/|www\.)[^\s<]+/i

      # A comment, CDATA section or tag (a `>` inside a quoted attribute does not end it), a lone `<`, or a run of text.
      # Every alternative ends at its terminator or consumes to the end of the text (an unterminated comment, CDATA
      # section or tag is one token to the end, as a browser reads it), and the repeats are possessive, so a long tag
      # neither exhausts the regex engine's stack nor is scanned twice.
      private URLIZE_TOKEN = /<!--(?:-?>|.*?--!?>|.*\z)|<!\[CDATA\[(?:.*?\]\]>|.*\z)|<[a-zA-Z\/!?](?:[^>"']++|"[^"]*+(?:"|\z)|'[^']*+(?:'|\z))*+(?:>|\z)|<|[^<]+/m

      # The characters that end a tag name in HTML (`\s` also matches a vertical tab and no-break spaces, which do not).
      private URLIZE_OPEN_ANCHOR  = /\A<a[ \t\n\f\r\/>]/i
      private URLIZE_CLOSE_ANCHOR = /\A<\/a[ \t\n\f\r\/>]/i

      # Elements whose content a reader does not see as prose, so it is never linked, and the end tag of each
      # (`plaintext` has none: it runs to the end of the text).
      private URLIZE_RAW_TEXT = /\A<(script|style|textarea|title|noscript|xmp|plaintext|iframe|noembed|noframes)(?=[ \t\n\f\r\/>])/i
      private URLIZE_RAW_END  = {
        "script"   => /\A<\/script[ \t\n\f\r\/>]/i,
        "style"    => /\A<\/style[ \t\n\f\r\/>]/i,
        "textarea" => /\A<\/textarea[ \t\n\f\r\/>]/i,
        "title"    => /\A<\/title[ \t\n\f\r\/>]/i,
        "noscript" => /\A<\/noscript[ \t\n\f\r\/>]/i,
        "xmp"      => /\A<\/xmp[ \t\n\f\r\/>]/i,
        "iframe"   => /\A<\/iframe[ \t\n\f\r\/>]/i,
        "noembed"  => /\A<\/noembed[ \t\n\f\r\/>]/i,
        "noframes" => /\A<\/noframes[ \t\n\f\r\/>]/i,
      }

      # Turns the http, https and `www.` addresses of *escaped_html_text* into links. Unlike Crinja's own `urlize`
      # it links no other scheme (`javascript://...` matches Crinja's pattern) and the text must already be escaped
      # (the `urlize` filter escapes it), so quotes in an address cannot leave the `href`. Markup in the text is
      # tolerated: tags and their attributes are copied untouched, and so are the text inside an `<a>` and the
      # contents of `<script>`, `<style>`, `<textarea>`, `<title>`, `<noscript>`, `<xmp>`, `<plaintext>`, `<iframe>`,
      # `<noembed>` and `<noframes>`. Invalid UTF-8 is replaced first. A single comment, CDATA section or tag larger
      # than a few MB exceeds the regex engine's limit: the text is then returned as it is, unlinked.
      #
      # It reads markup by a simplified HTML tokenizer, which differs from browsers in three known ways: a CDATA
      # section is treated as a section also in HTML content (browsers read it as a bogus comment ending at the
      # first `>`), a quote inside an attribute name starts a quoted value here (browsers keep it in the name), and
      # the script double-escape state (`<!-- <script>`) is not modelled, so `</script>` always ends a script.
      def urlize(escaped_html_text : String, trim_limit : Int32?, rel : Array(String), target : String?) : String
        rel_attr = rel.empty? ? "" : %( rel="#{escape_html(rel.join(' '))}")
        target_attr = target.nil? || target.empty? ? "" : %( target="#{escape_html(target)}")
        text = escaped_html_text.scrub
        begin
          link_text(text, trim_limit, rel_attr, target_attr)
        rescue Regex::Error
          # A single comment, CDATA section or tag of several MB exceeds the regex engine's match limit: fail safe.
          text
        end
      end

      private def link_text(text : String, trim_limit : Int32?, rel_attr : String, target_attr : String) : String
        in_anchor = false
        raw_text : String? = nil
        text.gsub(URLIZE_TOKEN) do |piece|
          if piece.starts_with?('<')
            if open_tag = raw_text
              raw_text = nil if URLIZE_RAW_END[open_tag]?.try(&.matches?(piece))
            else
              in_anchor = true if piece.matches?(URLIZE_OPEN_ANCHOR)
              in_anchor = false if piece.matches?(URLIZE_CLOSE_ANCHOR)
              if found = URLIZE_RAW_TEXT.match(piece)
                raw_text = found[1].downcase
              end
            end
            piece
          elsif in_anchor || raw_text
            piece
          else
            link_addresses(piece, trim_limit, rel_attr, target_attr)
          end
        end
      end

      private def link_addresses(text : String, trim_limit : Int32?, rel_attr : String, target_attr : String) : String
        text.gsub(URLIZE_PATTERN) do |address|
          display = address
          display = display[0..(trim_limit - 3)] + "..." if trim_limit && display.size >= trim_limit
          href = address.downcase.starts_with?("www.") ? "http://#{address}" : address
          %(<a href="#{href}"#{rel_attr}#{target_attr}>#{display}</a>)
        end
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

      # Builds HTML attributes string from a hash. Values are escaped; an attribute whose name is not a valid
      # name (`[a-zA-Z_:][-a-zA-Z0-9_:.]*`) is left out and logged.
      #
      # ```
      # Util.tag_attributes({class: "btn", id: "submit"})
      # # => "class=\"btn\" id=\"submit\""
      # ```
      def tag_attributes(attrs : Hash(String, String)) : String
        attrs.compact_map do |key, value|
          if !attribute_name?(key.to_s)
            Log.for("azu.helpers").warn { "attribute #{key.to_s.inspect} was left out: not a valid attribute name" }
            nil
          elsif value == "true" || value == true.to_s
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
        raise ArgumentError.new("invalid tag name #{name.inspect}") unless TAG_NAME.matches?(name)
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
          next if exclude.includes?(key_str) || !attribute_name?(key_str)

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
