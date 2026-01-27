module Azu
  module Helpers
    module Builtin
      # Asset helpers for including CSS, JavaScript, images, and other assets.
      #
      # ## Example
      #
      # ```jinja
      # <head>
      #   {{ stylesheet_tag("app.css") }}
      #   {{ favicon_tag("favicon.ico") }}
      # </head>
      # <body>
      #   {{ image_tag("logo.png", alt="Logo") }}
      #   {{ javascript_tag("app.js", defer=true) }}
      # </body>
      # ```
      module AssetHelpers
        # Default asset prefix
        @@asset_prefix = "/assets"
        @@asset_version : String? = nil
        @@manifest : Hash(String, String)? = nil

        def self.asset_prefix=(value : String)
          @@asset_prefix = value
        end

        def self.asset_version=(value : String?)
          @@asset_version = value
        end

        def self.register : Nil
          register_asset_path
          register_image_tag
          register_javascript_tag
          register_stylesheet_tag
          register_favicon_tag
          register_preload_tag
          register_inline_svg
        end

        private def self.register_asset_path : Nil
          filter = Crinja.filter({prefix: nil, version: nil}, :asset_path) do
            path = target.to_s
            prefix = arguments["prefix"]
            version = arguments["version"]

            asset_prefix = prefix.none? ? @@asset_prefix : prefix.to_s
            asset_version = version.none? ? @@asset_version : version.to_s

            full_path = File.join(asset_prefix, path)

            if asset_version && !asset_version.empty?
              "#{full_path}?v=#{asset_version}"
            else
              full_path
            end
          end
          Registry.register_filter(:asset_path, filter)
        end

        private def self.register_image_tag : Nil
          func = Crinja.function({
            src:     "",
            alt:     "",
            width:   nil,
            height:  nil,
            class:   nil,
            id:      nil,
            loading: nil,
            srcset:  nil,
            sizes:   nil,
            data:    nil,
          }, :image_tag) do
            src = arguments["src"].to_s
            alt = arguments["alt"].to_s
            width = arguments["width"]
            height = arguments["height"]
            css_class = arguments["class"]
            id = arguments["id"]
            loading = arguments["loading"]
            srcset = arguments["srcset"]
            sizes = arguments["sizes"]

            # Build full path
            full_src = if src.starts_with?("http://") || src.starts_with?("https://") || src.starts_with?("/")
                         src
                       else
                         File.join(@@asset_prefix, src)
                       end

            attrs = {
              "src" => full_src,
              "alt" => alt,
            }

            attrs["width"] = width.to_s unless width.none?
            attrs["height"] = height.to_s unless height.none?
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?
            attrs["loading"] = loading.to_s unless loading.none?
            attrs["srcset"] = srcset.to_s unless srcset.none?
            attrs["sizes"] = sizes.to_s unless sizes.none?

            Crinja::SafeString.new(Util.void_tag("img", attrs))
          end
          Registry.register_function(:image_tag, func)
        end

        private def self.register_javascript_tag : Nil
          func = Crinja.function({
            src:         "",
            async:       false,
            defer:       false,
            type:        nil,
            crossorigin: nil,
            integrity:   nil,
            nomodule:    false,
            id:          nil,
          }, :javascript_tag) do
            src = arguments["src"].to_s
            is_async = arguments["async"].truthy?
            is_defer = arguments["defer"].truthy?
            type = arguments["type"]
            crossorigin = arguments["crossorigin"]
            integrity = arguments["integrity"]
            is_nomodule = arguments["nomodule"].truthy?
            id = arguments["id"]

            # Build full path
            full_src = if src.starts_with?("http://") || src.starts_with?("https://") || src.starts_with?("/")
                         src
                       else
                         File.join(@@asset_prefix, src)
                       end

            # Add version if configured
            if version = @@asset_version
              full_src = "#{full_src}?v=#{version}"
            end

            attrs = {"src" => full_src}
            attrs["async"] = "async" if is_async
            attrs["defer"] = "defer" if is_defer
            attrs["type"] = type.to_s unless type.none?
            attrs["crossorigin"] = crossorigin.to_s unless crossorigin.none?
            attrs["integrity"] = integrity.to_s unless integrity.none?
            attrs["nomodule"] = "nomodule" if is_nomodule
            attrs["id"] = id.to_s unless id.none?

            Crinja::SafeString.new(Util.tag("script", attrs, ""))
          end
          Registry.register_function(:javascript_tag, func)
        end

        private def self.register_stylesheet_tag : Nil
          func = Crinja.function({
            href:        "",
            media:       nil,
            crossorigin: nil,
            integrity:   nil,
            id:          nil,
          }, :stylesheet_tag) do
            href = arguments["href"].to_s
            media = arguments["media"]
            crossorigin = arguments["crossorigin"]
            integrity = arguments["integrity"]
            id = arguments["id"]

            # Build full path
            full_href = if href.starts_with?("http://") || href.starts_with?("https://") || href.starts_with?("/")
                          href
                        else
                          File.join(@@asset_prefix, href)
                        end

            # Add version if configured
            if version = @@asset_version
              full_href = "#{full_href}?v=#{version}"
            end

            attrs = {
              "rel"  => "stylesheet",
              "href" => full_href,
            }
            attrs["media"] = media.to_s unless media.none?
            attrs["crossorigin"] = crossorigin.to_s unless crossorigin.none?
            attrs["integrity"] = integrity.to_s unless integrity.none?
            attrs["id"] = id.to_s unless id.none?

            Crinja::SafeString.new(Util.void_tag("link", attrs))
          end
          Registry.register_function(:stylesheet_tag, func)
        end

        private def self.register_favicon_tag : Nil
          func = Crinja.function({
            href: "favicon.ico",
            type: nil,
          }, :favicon_tag) do
            href = arguments["href"].to_s
            type = arguments["type"]

            # Build full path
            full_href = if href.starts_with?("http://") || href.starts_with?("https://") || href.starts_with?("/")
                          href
                        else
                          File.join(@@asset_prefix, href)
                        end

            # Determine type from extension
            mime_type = if type.none?
                          case File.extname(href).downcase
                          when ".ico"          then "image/x-icon"
                          when ".png"          then "image/png"
                          when ".svg"          then "image/svg+xml"
                          when ".gif"          then "image/gif"
                          when ".jpg", ".jpeg" then "image/jpeg"
                          else                      "image/x-icon"
                          end
                        else
                          type.to_s
                        end

            attrs = {
              "rel"  => "icon",
              "href" => full_href,
              "type" => mime_type,
            }

            Crinja::SafeString.new(Util.void_tag("link", attrs))
          end
          Registry.register_function(:favicon_tag, func)
        end

        private def self.register_preload_tag : Nil
          func = Crinja.function({
            href:        "",
            as:          "",
            type:        nil,
            crossorigin: nil,
          }, :preload_tag) do
            href = arguments["href"].to_s
            as_type = arguments["as"].to_s
            type = arguments["type"]
            crossorigin = arguments["crossorigin"]

            # Build full path
            full_href = if href.starts_with?("http://") || href.starts_with?("https://") || href.starts_with?("/")
                          href
                        else
                          File.join(@@asset_prefix, href)
                        end

            attrs = {
              "rel"  => "preload",
              "href" => full_href,
              "as"   => as_type,
            }
            attrs["type"] = type.to_s unless type.none?

            # Handle crossorigin - fonts require it
            if !crossorigin.none?
              attrs["crossorigin"] = crossorigin.truthy? ? "anonymous" : crossorigin.to_s
            elsif as_type == "font"
              attrs["crossorigin"] = "anonymous"
            end

            Crinja::SafeString.new(Util.void_tag("link", attrs))
          end
          Registry.register_function(:preload_tag, func)
        end

        private def self.register_inline_svg : Nil
          func = Crinja.function({
            path:   "",
            class:  nil,
            id:     nil,
            width:  nil,
            height: nil,
            title:  nil,
          }, :inline_svg) do
            path = arguments["path"].to_s
            css_class = arguments["class"]
            id = arguments["id"]
            width = arguments["width"]
            height = arguments["height"]
            title = arguments["title"]

            # Try to read SVG file
            full_path = if path.starts_with?("/")
                          path
                        else
                          File.join("public", @@asset_prefix.lstrip('/'), path)
                        end

            svg_content = begin
              File.read(full_path)
            rescue
              # Return placeholder if file not found
              %Q(<svg class="svg-placeholder"><text>SVG not found: #{Util.escape_html(path)}</text></svg>)
            end

            # Add attributes to SVG tag
            if !css_class.none? || !id.none? || !width.none? || !height.none?
              attrs = [] of String
              attrs << %Q(class="#{css_class}") unless css_class.none?
              attrs << %Q(id="#{id}") unless id.none?
              attrs << %Q(width="#{width}") unless width.none?
              attrs << %Q(height="#{height}") unless height.none?

              if !attrs.empty?
                # Insert attributes into SVG tag
                svg_content = svg_content.sub(/<svg/, "<svg #{attrs.join(" ")}")
              end
            end

            # Add title for accessibility
            unless title.none?
              title_tag = %Q(<title>#{Util.escape_html(title.to_s)}</title>)
              svg_content = svg_content.sub(/>/, ">#{title_tag}")
            end

            Crinja::SafeString.new(svg_content)
          end
          Registry.register_function(:inline_svg, func)
        end
      end
    end
  end
end
