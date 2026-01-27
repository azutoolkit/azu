module Azu
  module Helpers
    module Builtin
      # URL helpers for generating links, buttons, and navigation elements.
      #
      # ## Example
      #
      # ```jinja
      # <nav>
      #   {{ link_to("Home", "/", class="nav-link " ~ ("/" | active_class("active"))) }}
      #   {{ link_to("About", "/about") }}
      # </nav>
      #
      # {{ button_to("Delete", "/posts/1", method="delete", confirm="Are you sure?") }}
      # {{ mail_to("support@example.com", "Contact Us") }}
      # ```
      module UrlHelpers
        def self.register : Nil
          register_link_to
          register_button_to
          register_mail_to
          register_current_path
          register_current_url
          register_current_page
          register_active_class
          register_back_url
        end

        private def self.register_link_to : Nil
          func = Crinja.function({
            text:   "",
            href:   "",
            class:  nil,
            id:     nil,
            target: nil,
            rel:    nil,
            title:  nil,
            data:   nil,
          }, :link_to) do
            text = arguments["text"].to_s
            href = arguments["href"].to_s
            css_class = arguments["class"]
            id = arguments["id"]
            target = arguments["target"]
            rel = arguments["rel"]
            title = arguments["title"]
            data = arguments["data"]

            attrs = {"href" => href}
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?
            attrs["target"] = target.to_s unless target.none?
            attrs["title"] = title.to_s unless title.none?

            # Handle rel attribute - add noopener for external links
            if !rel.none?
              attrs["rel"] = rel.to_s
            elsif !target.none? && target.to_s == "_blank"
              attrs["rel"] = "noopener noreferrer"
            end

            # Add data attributes
            unless data.none?
              if data.raw.is_a?(Hash)
                data.as_h.each do |k, v|
                  attrs["data-#{k}"] = v.to_s
                end
              end
            end

            Crinja::SafeString.new(Util.tag("a", attrs, Util.escape_html(text)))
          end
          Registry.register_function(:link_to, func)
        end

        private def self.register_button_to : Nil
          func = Crinja.function({
            text:     "",
            href:     "",
            method:   "post",
            class:    nil,
            id:       nil,
            confirm:  nil,
            data:     nil,
            disabled: false,
          }, :button_to) do
            text = arguments["text"].to_s
            href = arguments["href"].to_s
            method = arguments["method"].to_s.downcase
            css_class = arguments["class"]
            id = arguments["id"]
            confirm = arguments["confirm"]
            data = arguments["data"]
            disabled = arguments["disabled"].truthy?

            # Build form
            form_method = method.in?("get", "post") ? method : "post"

            form_attrs = {
              "action" => href,
              "method" => form_method,
              "style"  => "display: inline;",
            }

            # Add confirm dialog via data attribute
            unless confirm.none?
              form_attrs["data-confirm"] = confirm.to_s
              form_attrs["onsubmit"] = "return confirm('#{Util.escape_html(confirm.to_s).gsub("'", "\\'")}');"
            end

            # Build button
            button_attrs = {"type" => "submit"}
            button_attrs["class"] = css_class.to_s unless css_class.none?
            button_attrs["id"] = id.to_s unless id.none?
            button_attrs["disabled"] = "disabled" if disabled

            # Add data attributes to button
            unless data.none?
              if data.raw.is_a?(Hash)
                data.as_h.each do |k, v|
                  button_attrs["data-#{k}"] = v.to_s
                end
              end
            end

            html = String.build do |io|
              io << "<form #{Util.tag_attributes(form_attrs)}>"

              # Add CSRF token from context if available
              csrf_val = env.context["csrf_token"]
              if !csrf_val.none? && !csrf_val.undefined?
                io << %Q(<input type="hidden" name="_csrf" value="#{csrf_val}" />)
              end

              # Add method override for non-standard methods
              if method.in?("delete", "put", "patch")
                io << %Q(<input type="hidden" name="_method" value="#{method}" />)
              end

              io << Util.tag("button", button_attrs, Util.escape_html(text))
              io << "</form>"
            end

            Crinja::SafeString.new(html)
          end
          Registry.register_function(:button_to, func)
        end

        private def self.register_mail_to : Nil
          func = Crinja.function({
            email:   "",
            text:    nil,
            subject: nil,
            body:    nil,
            cc:      nil,
            bcc:     nil,
            class:   nil,
            id:      nil,
          }, :mail_to) do
            email = arguments["email"].to_s
            text = arguments["text"]
            subject = arguments["subject"]
            body = arguments["body"]
            cc = arguments["cc"]
            bcc = arguments["bcc"]
            css_class = arguments["class"]
            id = arguments["id"]

            # Build mailto URL with parameters
            href = "mailto:#{email}"
            params = [] of String

            params << "subject=#{URI.encode_www_form(subject.to_s)}" unless subject.none?
            params << "body=#{URI.encode_www_form(body.to_s)}" unless body.none?
            params << "cc=#{URI.encode_www_form(cc.to_s)}" unless cc.none?
            params << "bcc=#{URI.encode_www_form(bcc.to_s)}" unless bcc.none?

            href += "?#{params.join("&")}" unless params.empty?

            # Use email as text if not provided
            display_text = text.none? ? email : text.to_s

            attrs = {"href" => href}
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?

            Crinja::SafeString.new(Util.tag("a", attrs, Util.escape_html(display_text)))
          end
          Registry.register_function(:mail_to, func)
        end

        private def self.register_current_path : Nil
          func = Crinja.function(:current_path) do
            val = env.context["current_path"]
            (!val.none? && !val.undefined?) ? val.to_s : ""
          end
          Registry.register_function(:current_path, func)
        end

        private def self.register_current_url : Nil
          func = Crinja.function(:current_url) do
            val = env.context["current_url"]
            (!val.none? && !val.undefined?) ? val.to_s : ""
          end
          Registry.register_function(:current_url, func)
        end

        private def self.register_current_page : Nil
          filter = Crinja.filter({exact: true}, :is_current_page) do
            path = target.to_s
            path_val = env.context["current_path"]
            current = (!path_val.none? && !path_val.undefined?) ? path_val.to_s : "/"
            exact = arguments["exact"].truthy?

            if exact
              current == path
            else
              current.starts_with?(path)
            end
          end
          Registry.register_filter(:is_current_page, filter)
          # Also register with ? suffix as alias (may not work in all contexts)
          Registry.register_filter(:"current_page?", filter)
        end

        private def self.register_active_class : Nil
          filter = Crinja.filter({class_name: "active", inactive_class: "", exact: true}, :active_class) do
            path = target.to_s
            class_name = arguments["class_name"].to_s
            inactive_class = arguments["inactive_class"].to_s
            exact = arguments["exact"].truthy?
            path_val = env.context["current_path"]
            current = (!path_val.none? && !path_val.undefined?) ? path_val.to_s : "/"

            is_active = if exact
                          current == path
                        else
                          current.starts_with?(path)
                        end

            is_active ? class_name : inactive_class
          end
          Registry.register_filter(:active_class, filter)
        end

        private def self.register_back_url : Nil
          func = Crinja.function({fallback: "/"}, :back_url) do
            fallback = arguments["fallback"].to_s

            # Try to get referer from context
            ref_val = env.context["http_referer"]
            referer = (!ref_val.none? && !ref_val.undefined?) ? ref_val.to_s : nil

            if referer && !referer.empty?
              referer
            else
              fallback
            end
          end
          Registry.register_function(:back_url, func)
        end
      end
    end
  end
end
