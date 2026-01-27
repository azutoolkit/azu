module Azu
  module Helpers
    module Builtin
      # Form helpers for building HTML forms with CSRF protection.
      #
      # ## Example
      #
      # ```jinja
      # {{ form_tag("/users", method="post") }}
      #   {{ csrf_field() }}
      #   {{ label_tag("user_name", "Name") }}
      #   {{ text_field("user", "name", required=true) }}
      #   {{ submit_button("Create") }}
      # {{ end_form() }}
      # ```
      module FormHelpers
        def self.register : Nil
          register_form_tag
          register_end_form
          register_text_field
          register_password_field
          register_email_field
          register_number_field
          register_textarea
          register_hidden_field
          register_checkbox
          register_radio_button
          register_select_field
          register_label_tag
          register_submit_button
          register_csrf_field
          register_csrf_meta
        end

        private def self.register_form_tag : Nil
          func = Crinja.function({
            action:    "",
            method:    "post",
            class:     nil,
            id:        nil,
            enctype:   nil,
            multipart: false,
            data:      nil,
            onsubmit:  nil,
          }, :form_tag) do
            action = arguments["action"].to_s
            method = arguments["method"].to_s.downcase
            css_class = arguments["class"]
            id = arguments["id"]
            enctype = arguments["enctype"]
            multipart = arguments["multipart"].truthy?
            data = arguments["data"]
            onsubmit = arguments["onsubmit"]

            # Build attributes
            attrs = {"action" => action}

            # Handle method override for non-standard methods
            actual_method = method
            if method.in?("delete", "put", "patch")
              actual_method = "post"
            end
            attrs["method"] = actual_method

            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?

            # Handle enctype - multipart=true takes precedence
            if multipart
              attrs["enctype"] = "multipart/form-data"
            elsif !enctype.none?
              attrs["enctype"] = enctype.to_s
            end

            attrs["onsubmit"] = onsubmit.to_s unless onsubmit.none?

            # Add data attributes
            unless data.none?
              if data.raw.is_a?(Hash)
                data.as_h.each do |k, v|
                  attrs["data-#{k}"] = v.to_s
                end
              end
            end

            # Build form opening tag
            attr_str = Util.tag_attributes(attrs)
            html = "<form #{attr_str}>"

            # Add method override hidden field if needed
            if method.in?("delete", "put", "patch")
              html += %Q(<input type="hidden" name="_method" value="#{method}" />)
            end

            Crinja::SafeString.new(html)
          end
          Registry.register_function(:form_tag, func)
        end

        private def self.register_end_form : Nil
          func = Crinja.function(:end_form) do
            Crinja::SafeString.new("</form>")
          end
          Registry.register_function(:end_form, func)
        end

        private def self.register_text_field : Nil
          func = Crinja.function({
            object:      "",
            attribute:   "",
            value:       nil,
            placeholder: nil,
            class:       nil,
            id:          nil,
            required:    false,
            disabled:    false,
            readonly:    false,
            autofocus:   false,
            maxlength:   nil,
            minlength:   nil,
            pattern:     nil,
            data:        nil,
          }, :text_field) do
            build_input_field("text", arguments)
          end
          Registry.register_function(:text_field, func)
        end

        private def self.register_password_field : Nil
          func = Crinja.function({
            object:      "",
            attribute:   "",
            placeholder: nil,
            class:       nil,
            id:          nil,
            required:    false,
            disabled:    false,
            autofocus:   false,
            minlength:   nil,
            maxlength:   nil,
            data:        nil,
          }, :password_field) do
            build_input_field("password", arguments)
          end
          Registry.register_function(:password_field, func)
        end

        private def self.register_email_field : Nil
          func = Crinja.function({
            object:      "",
            attribute:   "",
            value:       nil,
            placeholder: nil,
            class:       nil,
            id:          nil,
            required:    false,
            disabled:    false,
            readonly:    false,
            autofocus:   false,
            data:        nil,
          }, :email_field) do
            build_input_field("email", arguments)
          end
          Registry.register_function(:email_field, func)
        end

        private def self.register_number_field : Nil
          func = Crinja.function({
            object:      "",
            attribute:   "",
            value:       nil,
            placeholder: nil,
            class:       nil,
            id:          nil,
            required:    false,
            disabled:    false,
            readonly:    false,
            autofocus:   false,
            min:         nil,
            max:         nil,
            step:        nil,
            data:        nil,
          }, :number_field) do
            args = arguments
            attrs = build_common_attrs(args)
            attrs["type"] = "number"

            min = args["min"]
            max = args["max"]
            step = args["step"]

            attrs["min"] = min.to_s unless min.none?
            attrs["max"] = max.to_s unless max.none?
            attrs["step"] = step.to_s unless step.none?

            Crinja::SafeString.new(Util.void_tag("input", attrs))
          end
          Registry.register_function(:number_field, func)
        end

        private def self.register_textarea : Nil
          func = Crinja.function({
            object:      "",
            attribute:   "",
            value:       nil,
            placeholder: nil,
            class:       nil,
            id:          nil,
            required:    false,
            disabled:    false,
            readonly:    false,
            rows:        nil,
            cols:        nil,
            data:        nil,
          }, :textarea) do
            args = arguments
            object = args["object"].to_s
            attribute = args["attribute"].to_s
            value = args["value"]
            css_class = args["class"]
            id = args["id"]
            rows = args["rows"]
            cols = args["cols"]
            placeholder = args["placeholder"]

            field_name = object.empty? ? attribute : "#{object}[#{attribute}]"
            field_id = id.none? ? "#{object}_#{attribute}".gsub(/[\[\]]/, "_") : id.to_s

            attrs = {
              "name" => field_name,
              "id"   => field_id,
            }

            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["rows"] = rows.to_s unless rows.none?
            attrs["cols"] = cols.to_s unless cols.none?
            attrs["placeholder"] = placeholder.to_s unless placeholder.none?

            attrs["required"] = "required" if args["required"].truthy?
            attrs["disabled"] = "disabled" if args["disabled"].truthy?
            attrs["readonly"] = "readonly" if args["readonly"].truthy?

            content = value.none? ? "" : Util.escape_html(value.to_s)
            Crinja::SafeString.new(Util.tag("textarea", attrs, content))
          end
          Registry.register_function(:textarea, func)
        end

        private def self.register_hidden_field : Nil
          func = Crinja.function({
            object:    "",
            attribute: "",
            value:     "",
            id:        nil,
          }, :hidden_field) do
            args = arguments
            object = args["object"].to_s
            attribute = args["attribute"].to_s
            value = args["value"].to_s
            id = args["id"]

            field_name = object.empty? ? attribute : "#{object}[#{attribute}]"
            field_id = id.none? ? "#{object}_#{attribute}".gsub(/[\[\]]/, "_") : id.to_s

            attrs = {
              "type"  => "hidden",
              "name"  => field_name,
              "id"    => field_id,
              "value" => value,
            }

            Crinja::SafeString.new(Util.void_tag("input", attrs))
          end
          Registry.register_function(:hidden_field, func)
        end

        private def self.register_checkbox : Nil
          func = Crinja.function({
            object:    "",
            attribute: "",
            value:     "1",
            checked:   false,
            class:     nil,
            id:        nil,
            disabled:  false,
            label:     nil,
            data:      nil,
          }, :checkbox) do
            args = arguments
            object = args["object"].to_s
            attribute = args["attribute"].to_s
            value = args["value"].to_s
            checked = args["checked"].truthy?
            css_class = args["class"]
            id = args["id"]
            disabled = args["disabled"].truthy?
            label = args["label"]

            field_name = object.empty? ? attribute : "#{object}[#{attribute}]"
            field_id = id.none? ? "#{object}_#{attribute}".gsub(/[\[\]]/, "_") : id.to_s

            # Hidden field for unchecked state
            hidden = %Q(<input type="hidden" name="#{field_name}" value="0" />)

            # Checkbox
            attrs = {
              "type"  => "checkbox",
              "name"  => field_name,
              "id"    => field_id,
              "value" => value,
            }
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["checked"] = "checked" if checked
            attrs["disabled"] = "disabled" if disabled

            checkbox = Util.void_tag("input", attrs)

            html = hidden + checkbox

            # Add label if provided
            unless label.none?
              html += %Q( <label for="#{field_id}">#{Util.escape_html(label.to_s)}</label>)
            end

            Crinja::SafeString.new(html)
          end
          Registry.register_function(:checkbox, func)
        end

        private def self.register_radio_button : Nil
          func = Crinja.function({
            object:    "",
            attribute: "",
            value:     "",
            checked:   false,
            class:     nil,
            id:        nil,
            disabled:  false,
            label:     nil,
            data:      nil,
          }, :radio_button) do
            args = arguments
            object = args["object"].to_s
            attribute = args["attribute"].to_s
            value = args["value"].to_s
            checked = args["checked"].truthy?
            css_class = args["class"]
            id = args["id"]
            disabled = args["disabled"].truthy?
            label = args["label"]

            field_name = object.empty? ? attribute : "#{object}[#{attribute}]"
            field_id = if id.none?
                         "#{object}_#{attribute}_#{value}".gsub(/[\[\]\s]/, "_")
                       else
                         id.to_s
                       end

            attrs = {
              "type"  => "radio",
              "name"  => field_name,
              "id"    => field_id,
              "value" => value,
            }
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["checked"] = "checked" if checked
            attrs["disabled"] = "disabled" if disabled

            html = Util.void_tag("input", attrs)

            # Add label if provided
            unless label.none?
              html += %Q( <label for="#{field_id}">#{Util.escape_html(label.to_s)}</label>)
            end

            Crinja::SafeString.new(html)
          end
          Registry.register_function(:radio_button, func)
        end

        private def self.register_select_field : Nil
          func = Crinja.function({
            object:        "",
            attribute:     "",
            options:       [] of String,
            selected:      nil,
            include_blank: nil,
            class:         nil,
            id:            nil,
            required:      false,
            disabled:      false,
            multiple:      false,
            data:          nil,
          }, :select_field) do
            args = arguments
            object = args["object"].to_s
            attribute = args["attribute"].to_s
            options = args["options"]
            selected = args["selected"]
            include_blank = args["include_blank"]
            css_class = args["class"]
            id = args["id"]
            required = args["required"].truthy?
            disabled = args["disabled"].truthy?
            multiple = args["multiple"].truthy?

            field_name = object.empty? ? attribute : "#{object}[#{attribute}]"
            field_name += "[]" if multiple
            field_id = id.none? ? "#{object}_#{attribute}".gsub(/[\[\]]/, "_") : id.to_s

            attrs = {
              "name" => field_name,
              "id"   => field_id,
            }
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["required"] = "required" if required
            attrs["disabled"] = "disabled" if disabled
            attrs["multiple"] = "multiple" if multiple

            # Build options HTML
            options_html = String.build do |io|
              # Include blank option
              unless include_blank.none?
                blank_text = include_blank.to_s
                blank_text = "" if blank_text == "true"
                io << %Q(<option value="">#{Util.escape_html(blank_text)}</option>)
              end

              # Build options
              if options.iterable?
                options.each do |opt|
                  if opt.raw.is_a?(Hash)
                    opt_hash = opt.as_h
                    opt_value = opt_hash[Crinja::Value.new("value")]?.try(&.to_s) || ""
                    opt_label = opt_hash[Crinja::Value.new("label")]?.try(&.to_s) || opt_value
                    opt_disabled = opt_hash[Crinja::Value.new("disabled")]?.try(&.truthy?) || false

                    is_selected = !selected.none? && selected.to_s == opt_value
                    selected_attr = is_selected ? " selected" : ""
                    disabled_attr = opt_disabled ? " disabled" : ""

                    io << %Q(<option value="#{Util.escape_html(opt_value)}"#{selected_attr}#{disabled_attr}>)
                    io << Util.escape_html(opt_label)
                    io << "</option>"
                  else
                    opt_value = opt.to_s
                    is_selected = !selected.none? && selected.to_s == opt_value
                    selected_attr = is_selected ? " selected" : ""

                    io << %Q(<option value="#{Util.escape_html(opt_value)}"#{selected_attr}>)
                    io << Util.escape_html(opt_value)
                    io << "</option>"
                  end
                end
              end
            end

            Crinja::SafeString.new(Util.tag("select", attrs, options_html))
          end
          Registry.register_function(:select_field, func)
        end

        private def self.register_label_tag : Nil
          func = Crinja.function({
            for_field: "",
            text:      "",
            class:     nil,
            id:        nil,
          }, :label_tag) do
            args = arguments
            for_field = args["for_field"].to_s
            text = args["text"].to_s
            css_class = args["class"]
            id = args["id"]

            attrs = {"for" => for_field}
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?

            Crinja::SafeString.new(Util.tag("label", attrs, Util.escape_html(text)))
          end
          Registry.register_function(:label_tag, func)
        end

        private def self.register_submit_button : Nil
          func = Crinja.function({
            text:     "Submit",
            class:    nil,
            id:       nil,
            disabled: false,
            name:     nil,
            value:    nil,
            data:     nil,
          }, :submit_button) do
            args = arguments
            text = args["text"].to_s
            css_class = args["class"]
            id = args["id"]
            disabled = args["disabled"].truthy?
            name = args["name"]
            value = args["value"]

            attrs = {"type" => "submit"}
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?
            attrs["disabled"] = "disabled" if disabled
            attrs["name"] = name.to_s unless name.none?
            attrs["value"] = value.to_s unless value.none?

            Crinja::SafeString.new(Util.tag("button", attrs, Util.escape_html(text)))
          end
          Registry.register_function(:submit_button, func)
        end

        private def self.register_csrf_field : Nil
          func = Crinja.function(:csrf_field) do
            csrf_val = env.context["csrf_token"]
            token = (!csrf_val.none? && !csrf_val.undefined?) ? csrf_val.to_s : ""
            Crinja::SafeString.new(%Q(<input type="hidden" name="_csrf" value="#{token}" />))
          end
          Registry.register_function(:csrf_field, func)
        end

        private def self.register_csrf_meta : Nil
          func = Crinja.function(:csrf_meta) do
            csrf_val = env.context["csrf_token"]
            token = (!csrf_val.none? && !csrf_val.undefined?) ? csrf_val.to_s : ""
            Crinja::SafeString.new(%Q(<meta name="csrf-token" content="#{token}" />))
          end
          Registry.register_function(:csrf_meta, func)
        end

        # Helper to build common input field
        private def self.build_input_field(type : String, args : Crinja::Arguments) : Crinja::SafeString
          attrs = build_common_attrs(args)
          attrs["type"] = type
          Crinja::SafeString.new(Util.void_tag("input", attrs))
        end

        # Build common attributes for input fields
        private def self.build_common_attrs(args : Crinja::Arguments) : Hash(String, String)
          object = args["object"].to_s
          attribute = args["attribute"].to_s

          field_name = object.empty? ? attribute : "#{object}[#{attribute}]"

          # Check if we have a custom id
          id_val = safe_get_arg(args, "id")
          field_id = (id_val.nil? || id_val.none?) ? "#{object}_#{attribute}".gsub(/[\[\]]/, "_") : id_val.to_s

          attrs = {
            "name" => field_name,
            "id"   => field_id,
          }

          # Optional string attributes
          if value = safe_get_arg(args, "value")
            attrs["value"] = value.to_s unless value.none?
          end
          if css_class = safe_get_arg(args, "class")
            attrs["class"] = css_class.to_s unless css_class.none?
          end
          if placeholder = safe_get_arg(args, "placeholder")
            attrs["placeholder"] = placeholder.to_s unless placeholder.none?
          end

          # Boolean attributes
          if required = safe_get_arg(args, "required")
            attrs["required"] = "required" if required.truthy?
          end
          if disabled = safe_get_arg(args, "disabled")
            attrs["disabled"] = "disabled" if disabled.truthy?
          end
          if readonly = safe_get_arg(args, "readonly")
            attrs["readonly"] = "readonly" if readonly.truthy?
          end
          if autofocus = safe_get_arg(args, "autofocus")
            attrs["autofocus"] = "autofocus" if autofocus.truthy?
          end

          # Length attributes
          if maxlength = safe_get_arg(args, "maxlength")
            attrs["maxlength"] = maxlength.to_s unless maxlength.none?
          end
          if minlength = safe_get_arg(args, "minlength")
            attrs["minlength"] = minlength.to_s unless minlength.none?
          end

          # Pattern
          if pattern = safe_get_arg(args, "pattern")
            attrs["pattern"] = pattern.to_s unless pattern.none?
          end

          attrs
        end

        # Safely get an argument, returning nil if not defined
        private def self.safe_get_arg(args : Crinja::Arguments, key : String) : Crinja::Value?
          args[key]
        rescue Crinja::Arguments::UnknownArgumentError
          nil
        end
      end
    end
  end
end
