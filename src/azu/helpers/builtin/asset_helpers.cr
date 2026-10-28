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

        # The URL an asset helper prints for *path*: an `http(s)://` URL or a site-absolute path as given, anything
        # else below the asset prefix. Site-absolute means one `/` followed by an ordinary character: `//host/x`,
        # `/\host/x` and `/<tab>/host/x` would load from another host (browsers read `\` and skip control characters),
        # so they are prefixed like a relative path.
        protected def self.asset_url(path : String) : String
          return path if path.matches?(%r{\Ahttps?://}i) || site_absolute?(path)
          # Not File.join: with a root prefix ("" or "/") it would hand `//host/x` back as it came
          "#{@@asset_prefix.chomp('/')}/#{path.lstrip("/\\")}"
        end

        private def self.site_absolute?(path : String) : Bool
          return false unless path.starts_with?('/')
          second = path[1]?
          second.nil? || !(second == '/' || second == '\\' || second.ascii_whitespace? || second.ascii_control?)
        end

        # Where `inline_svg` reads from: `public/<asset prefix>` of the working directory, without a trailing slash.
        protected def self.svg_directory : String
          File.expand_path(File.join("public", @@asset_prefix.strip('/'))).chomp('/')
        end

        # The file *path* names below `svg_directory`, nil when it names one outside it (`..`, an absolute path, a
        # symbolic link that leads out). Paths are resolved (`File.realpath`), so a link inside the directory that
        # points outside it is refused too; a file that does not exist is nil as well.
        protected def self.svg_path(path : String) : String?
          return if path.empty? || path.starts_with?('/') || path.includes?('\0')
          directory = File.realpath(svg_directory)
          full = File.realpath(File.expand_path(path, directory))
          full if full.starts_with?(directory + "/")
        rescue File::Error
          nil
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
            full_src = asset_url(src)

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
            full_src = asset_url(src)

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
            full_href = asset_url(href)

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
            full_href = asset_url(href)

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
            full_href = asset_url(href)

            attrs = {
              "rel"  => "preload",
              "href" => full_href,
              "as"   => as_type,
            }
            attrs["type"] = type.to_s unless type.none?

            # true means "anonymous", false omits the attribute, a string is used as given;
            # a font preload without the argument gets "anonymous", as browsers require it
            case raw = crossorigin.raw
            when String, Crinja::SafeString then attrs["crossorigin"] = raw.to_s
            when true                       then attrs["crossorigin"] = "anonymous"
            when nil, Crinja::Undefined     then attrs["crossorigin"] = "anonymous" if as_type == "font"
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

            # Only a file below the asset directory is read: the content is printed unescaped, so a path that
            # climbs out of it (or an absolute one) is treated like a missing file
            svg_content = begin
              if full_path = svg_path(path)
                File.read(full_path)
              else
                raise File::NotFoundError.new("outside the asset directory", file: path)
              end
            rescue
              # Return placeholder if file not found
              %Q(<svg class="svg-placeholder"><text>SVG not found: #{Util.escape_html(path)}</text></svg>)
            end

            # Add attributes to SVG tag
            if !css_class.none? || !id.none? || !width.none? || !height.none?
              attrs = [] of String
              attrs << %Q(class="#{Util.escape_html(css_class.to_s)}") unless css_class.none?
              attrs << %Q(id="#{Util.escape_html(id.to_s)}") unless id.none?
              attrs << %Q(width="#{Util.escape_html(width.to_s)}") unless width.none?
              attrs << %Q(height="#{Util.escape_html(height.to_s)}") unless height.none?

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
