module Azu
  module Helpers
    module Builtin
      # HTML helpers for generating and manipulating HTML content.
      #
      # ## Example
      #
      # ```jinja
      # {{ raw_html | safe_html }}
      # {{ text | simple_format }}
      # {{ content | highlight("search term") }}
      # {{ html | truncate_html(100) }}
      # {{ text | strip_tags }}
      # ```
      module HtmlHelpers
        def self.register : Nil
          register_safe_html
          register_simple_format
          register_highlight
          register_truncate_html
          register_strip_tags
          register_word_wrap
          register_auto_link
          register_cycle
          register_content_tag
        end

        private def self.register_safe_html : Nil
          filter = Crinja.filter(:safe_html) do
            Crinja::SafeString.new(target.to_s)
          end
          Registry.register_filter(:safe_html, filter)
        end

        private def self.register_simple_format : Nil
          filter = Crinja.filter({
            tag:        "p",
            html_attrs: nil,
          }, :simple_format) do
            text = target.to_s
            tag = arguments["tag"].to_s
            html_attrs = arguments["html_attrs"]

            # Build tag attributes
            attrs_str = ""
            unless html_attrs.none?
              if html_attrs.raw.is_a?(Hash)
                attrs_hash = html_attrs.as_h
                attrs = attrs_hash.map { |k, v| "#{k}=\"#{Util.escape_html(v.to_s)}\"" }
                attrs_str = " #{attrs.join(" ")}"
              end
            end

            # Split into paragraphs on double newlines
            paragraphs = text.split(/\n\n+/)

            html = paragraphs.map do |para|
              # Convert single newlines to <br>
              content = Util.escape_html(para.strip).gsub(/\r?\n/, "<br>")
              "<#{tag}#{attrs_str}>#{content}</#{tag}>"
            end.join("\n")

            Crinja::SafeString.new(html)
          end
          Registry.register_filter(:simple_format, filter)
        end

        private def self.register_highlight : Nil
          filter = Crinja.filter({
            phrase:      "",
            highlighter: "<mark>\\0</mark>",
          }, :highlight) do
            text = target.to_s
            phrase = arguments["phrase"].to_s
            highlighter = arguments["highlighter"].to_s

            if phrase.empty?
              text
            else
              result = Util.highlight(text, phrase, highlighter)
              Crinja::SafeString.new(result)
            end
          end
          Registry.register_filter(:highlight, filter)
        end

        private def self.register_truncate_html : Nil
          filter = Crinja.filter({
            length:   100,
            omission: "...",
          }, :truncate_html) do
            html = target.to_s
            length = arguments["length"].to_i
            omission = arguments["omission"].to_s

            Util.truncate_html(html, length, omission)
          end
          Registry.register_filter(:truncate_html, filter)
        end

        private def self.register_strip_tags : Nil
          filter = Crinja.filter(:strip_tags) do
            Util.strip_tags(target.to_s)
          end
          Registry.register_filter(:strip_tags, filter)
        end

        private def self.register_word_wrap : Nil
          filter = Crinja.filter({
            line_width: 80,
            break_char: "\n",
          }, :word_wrap) do
            text = target.to_s
            line_width = arguments["line_width"].to_i
            break_char = arguments["break_char"].to_s

            words = text.split(/\s+/)
            lines = [] of String
            current_line = ""

            words.each do |word|
              if current_line.empty?
                current_line = word
              elsif current_line.size + 1 + word.size <= line_width
                current_line += " #{word}"
              else
                lines << current_line
                current_line = word
              end
            end

            lines << current_line unless current_line.empty?
            lines.join(break_char)
          end
          Registry.register_filter(:word_wrap, filter)
        end

        private def self.register_auto_link : Nil
          filter = Crinja.filter({
            link_attrs: nil,
            sanitize:   true,
          }, :auto_link) do
            text = target.to_s
            link_attrs = arguments["link_attrs"]
            sanitize = arguments["sanitize"].truthy?

            # Escape HTML if sanitize is true
            text = Util.escape_html(text) if sanitize

            # Build link attributes
            attrs_str = ""
            unless link_attrs.none?
              if link_attrs.raw.is_a?(Hash)
                attrs_hash = link_attrs.as_h
                attrs = attrs_hash.map { |k, v| "#{k}=\"#{Util.escape_html(v.to_s)}\"" }
                attrs_str = " #{attrs.join(" ")}"
              end
            end

            # Add rel="noopener" for security
            if !attrs_str.includes?("rel=")
              attrs_str += " rel=\"noopener noreferrer\""
            end

            # URL regex pattern
            url_pattern = /\b(https?:\/\/[^\s<>\[\]"']+)/i

            # Email pattern
            email_pattern = /\b([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})\b/

            # Replace URLs with links
            result = text.gsub(url_pattern) do |match|
              url = match
              # Don't double-link already linked content
              %Q(<a href="#{url}"#{attrs_str}>#{url}</a>)
            end

            # Replace emails with mailto links
            result = result.gsub(email_pattern) do |match|
              email = match
              %Q(<a href="mailto:#{email}">#{email}</a>)
            end

            Crinja::SafeString.new(result)
          end
          Registry.register_filter(:auto_link, filter)
        end

        private def self.register_cycle : Nil
          # Cycle through values - useful in loops
          func = Crinja.function({values: [] of String}, :cycle) do
            values = arguments["values"]

            # Get or initialize cycle index from environment
            cycle_key = "__cycle_index__"
            cycle_val = env.context[cycle_key]
            index = (!cycle_val.none? && !cycle_val.undefined?) ? cycle_val.to_i : 0

            if values.iterable? && values.size > 0
              result = values.to_a[index % values.size].to_s

              # Increment index
              env.context[cycle_key] = Crinja::Value.new((index + 1) % values.size)

              result
            else
              ""
            end
          end
          Registry.register_function(:cycle, func)
        end

        private def self.register_content_tag : Nil
          func = Crinja.function({
            name:    "div",
            content: nil,
            class:   nil,
            id:      nil,
            data:    nil,
            attrs:   nil,
          }, :content_tag) do
            tag_name = arguments["name"].to_s
            content = arguments["content"]
            css_class = arguments["class"]
            id = arguments["id"]
            data = arguments["data"]
            extra_attrs = arguments["attrs"]

            attrs = {} of String => String
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?

            # Add data attributes
            unless data.none?
              if data.raw.is_a?(Hash)
                data.as_h.each do |k, v|
                  attrs["data-#{k}"] = v.to_s
                end
              end
            end

            # Add extra attributes
            unless extra_attrs.none?
              if extra_attrs.raw.is_a?(Hash)
                extra_attrs.as_h.each do |k, v|
                  attrs[k.to_s] = v.to_s
                end
              end
            end

            content_str = content.none? ? "" : content.to_s

            Crinja::SafeString.new(Util.tag(tag_name, attrs, content_str))
          end
          Registry.register_function(:content_tag, func)
        end
      end
    end
  end
end
