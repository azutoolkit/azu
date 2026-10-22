require "./status"

module Azu
  module Components
    module Dashboard
      # Reusable building blocks shared by every section.
      #
      # Mixed into DevDashboardComponent, so each method renders through the
      # Markup DSL: every dynamic text and attribute value is HTML-escaped there.
      # `raw` is reserved for static markup and numeric SVG coordinates.
      #
      # Wrappers that take a block capture it (`&block : ->` and `block.call`)
      # because Crystal cannot `yield` from inside the DSL's own captured block.
      module Widgets
        VERBS = %w[GET POST PUT PATCH DELETE]

        # Markup has no `p` (Kernel#p is taken) and its `para` emits a non-standard
        # <para> element, so paragraphs go through `tag`.
        private def paragraph(content : String, **attrs) : Nil
          tag("p", **attrs) { text content }
        end

        private def paragraph(**attrs, &block : ->) : Nil
          tag("p", **attrs) { block.call }
        end

        # Inline SVG referencing a symbol from the page's icon sprite.
        private def icon(name : String, classes : String = "") : Nil
          raw %(<svg class="azd-icon #{::HTML.escape(classes)}" aria-hidden="true" focusable="false"><use href="#i-#{::HTML.escape(name)}"/></svg>)
        end

        # Frosted-glass card with a titled header; `meta` is a muted note on its right.
        private def card(title : String, icon_name : String, meta : String? = nil, &block : ->) : Nil
          section class: "azd-card" do
            header class: "azd-card-head" do
              icon icon_name
              h3 title
              span meta, class: "azd-card-meta" if meta
            end
            div class: "azd-card-body" do
              block.call
            end
          end
        end

        # Headline metric card. `status` adds a badge captioned `badge_text`.
        private def kpi(label : String, icon_name : String, status : Status? = nil, badge_text : String = "", &block : ->) : Nil
          article class: "azd-card azd-kpi" do
            header class: "azd-kpi-head" do
              icon icon_name
              h3 label
              badge(status, badge_text) if status
            end
            block.call
          end
        end

        # Big number with an optional unit; a nil value renders the explicit "n/a" state.
        private def kpi_value(value : String?, unit : String = "", caption : String? = nil) : Nil
          div class: "azd-kpi-stat" do
            paragraph(class: value ? "azd-kpi-value" : "azd-kpi-value is-na") do
              text value || "n/a"
              span unit, class: "azd-unit" unless unit.empty? || value.nil?
            end
            paragraph caption, class: "azd-kpi-sub" if caption
          end
        end

        private def badge(status : Status, label : String) : Nil
          span class: "azd-badge #{status.css}" do
            span class: "azd-dot", aria_hidden: "true"
            text label
          end
        end

        private def na : Nil
          span "n/a", class: "azd-na"
        end

        # Renders the block for a present value, otherwise the "n/a" state.
        private def present(value : T?, & : T ->) : Nil forall T
          value.nil? ? na : yield(value)
        end

        # Good when there is nothing to report, otherwise `otherwise`.
        private def zero_is_good(count : Int, otherwise : Status) : Status
          count.zero? ? Status::Good : otherwise
        end

        # Colour-coded HTTP verb; anything else (cache, component, ...) gets the neutral style.
        private def verb_chip(tag : String) : Nil
          span tag, class: "azd-verb v-#{VERBS.includes?(tag) ? tag.downcase : "other"}"
        end

        # Icon-only button wired to a `data-action`; the label is its accessible name.
        private def icon_button(label : String, icon_name : String, action : String, **attrs) : Nil
          button(**{type: "button", class: "azd-icon-btn", data_action: action, aria_label: label, title: label}.merge(attrs)) do
            icon icon_name
          end
        end

        # Icon button copying `value`; without one the script copies the nearest
        # `.azd-code` block, or the search text of the enclosing `[data-filter]` row.
        private def copy_button(label : String, value : String? = nil) : Nil
          icon_button "Copy #{label}", "copy", "copy", data_copy: value
        end

        # Monospace block with a copy button, for SQL and other copyable text.
        private def code_block(source : String, label : String) : Nil
          div class: "azd-code" do
            pre source
            copy_button label
          end
        end

        private def sparkline(values : Array(Float64), label : String) : Nil
          return if values.size < 2

          low, high = values.minmax
          span_y = high > low ? high - low : 1.0
          points = values.map_with_index do |value, i|
            "#{(i * 100.0 / (values.size - 1)).round(1)},#{(30 - (value - low) / span_y * 28).round(1)}"
          end.join(' ')
          raw %(<svg class="azd-spark" viewBox="0 0 100 32" preserveAspectRatio="none" role="img" aria-label="#{::HTML.escape(label)}">) +
              %(<polygon points="0,32 #{points} 100,32"/><polyline points="#{points}"/></svg>)
        end

        private def meter(percent : Float64, status : Status, label : String) : Nil
          div class: "azd-meter #{status.css}", role: "meter", aria_label: label, aria_valuemin: "0", aria_valuemax: "100",
            aria_valuenow: percent.round(1).to_s do
            div class: "azd-meter-fill", style: "width: #{percent.clamp(0.0, 100.0).round(1)}%"
          end
        end

        private def empty_state(title : String, hint : String, icon_name : String = "check") : Nil
          div class: "azd-empty" do
            icon icon_name
            paragraph title, class: "azd-empty-title"
            paragraph hint
          end
        end

        # Label/value rows; use `fact` inside the block.
        private def facts(&block : ->) : Nil
          dl class: "azd-facts" do
            block.call
          end
        end

        private def fact(label : String, &block : ->) : Nil
          div class: "azd-fact" do
            dt label
            dd do
              block.call
            end
          end
        end

        private def fact(label : String, value : String) : Nil
          fact(label) { text value }
        end

        # Table inside a keyboard-scrollable region, so wide tables work on narrow screens.
        private def data_table(description : String, columns : Array(String), &block : ->) : Nil
          div class: "azd-scroll", role: "group", aria_label: description, tabindex: "0" do
            table class: "azd-table" do
              caption description, class: "azd-sr"
              thead do
                tr { columns.each { |column| th column, scope: "col" } }
              end
              tbody do
                block.call
              end
            end
          end
        end
      end
    end
  end
end
