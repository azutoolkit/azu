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
          register_urlize
          register_cycle
          register_content_tag
        end

        # The attributes of a Hash argument as strings; names are checked and values escaped by `Util.tag_attributes`.
        private def self.hash_attributes(value : Crinja::Value) : Hash(String, String)
          attrs = {} of String => String
          if !value.none? && value.raw.is_a?(Hash)
            value.as_h.each { |k, v| attrs[k.to_s] = v.to_s }
          end
          attrs
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

            attrs = hash_attributes(html_attrs)

            # Split into paragraphs on double newlines
            paragraphs = text.split(/\n\n+/)

            html = paragraphs.map do |para|
              # Convert single newlines to <br>
              content = Util.escape_html(para.strip).gsub(/\r?\n/, "<br>")
              Util.tag(tag, attrs, content)
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
            phrase = arguments["phrase"].to_s
            highlighter = arguments["highlighter"].to_s

            # Text that is already safe (a SafeString) is escaped HTML text: the phrase is escaped to match it.
            # Anything else is plain text and is escaped here, since the result is marked safe.
            result = if target.raw.is_a?(Crinja::SafeString)
                       Util.highlight(target.to_s, Util.escape_html(phrase), highlighter)
                     else
                       Util.highlight_html(target.to_s, phrase, highlighter)
                     end
            Crinja::SafeString.new(result)
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

            result = Util.truncate_html(html, length, omission)
            if target.raw.is_a?(Crinja::SafeString)
              # safe in, safe out: the result is the input or its text, both made of the same escaped HTML;
              # the omission is the template author's argument and may hold anything, so it is escaped
              result = result[0, result.size - omission.size] + Util.escape_html(omission) if result != html && result.ends_with?(omission)
              Crinja::SafeString.new(result)
            else
              result
            end
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

            attrs = hash_attributes(link_attrs)
            # Add rel="noopener" for security
            attrs["rel"] = "noopener noreferrer" unless attrs.has_key?("rel")
            attrs_str = " #{Util.tag_attributes(attrs)}"

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

        # Replaces Crinja's `urlize`, which does not escape the text around the links and links any `scheme://`.
        private def self.register_urlize : Nil
          filter = Crinja.filter({trim_url_limit: nil, nofollow: false, target: nil, rel: nil}, :urlize) do
            rel = arguments["rel"].to_s.split(' ')
            rel << "nofollow" if arguments["nofollow"].truthy?
            rel |= env.policies.fetch("urlize.rel", "noopener").to_s.split(' ')
            target_attr = arguments.fetch("target") { env.policies.fetch("urlize.target", nil) }.raw.as(String?)
            limit = arguments["trim_url_limit"].raw.as?(Int).try(&.to_i)

            text = target.raw.is_a?(Crinja::SafeString) ? target.to_s : Util.escape_html(target.to_s)
            Crinja::SafeString.new(Util.urlize(text, limit, rel.reject(&.empty?).uniq!, target_attr))
          end
          Registry.register_filter(:urlize, filter)
        end

        # Cycles through values. Inside `{% for %}` the value follows `loop.index0`, so every cycle in the
        # loop is independent; outside a loop each call advances a counter kept per list of values.
        private def self.register_cycle : Nil
          func = Crinja.function({values: [] of String}, :cycle) do
            values = arguments["values"]
            items = values.iterable? ? values.to_a : [] of Crinja::Value

            if items.empty?
              ""
            elsif loop = env.context["loop"].raw.as?(Crinja::Tag::For::ForLoop)
              items[loop.index0 % items.size].to_s
            else
              cycle_key = "__cycle__:" + items.join('\u{1f}')
              counter = env.context[cycle_key]
              index = counter.raw.is_a?(Int32) ? counter.raw.as(Int32) : 0
              env.context[cycle_key] = Crinja::Value.new((index + 1) % items.size)
              items[index].to_s
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

            # Content is text unless it is already safe markup (another helper's output, `| safe`)
            content_str = if content.none?
                            ""
                          elsif content.raw.is_a?(Crinja::SafeString)
                            content.to_s
                          else
                            Util.escape_html(content.to_s)
                          end

            Crinja::SafeString.new(Util.tag(tag_name, attrs, content_str))
          end
          Registry.register_function(:content_tag, func)
        end
      end
    end
  end
end
