require "../error_store"

module Azu
  module Components
    module Dashboard
      # "Errors" tab: every server error since boot in one place, one row per failure (grouped by the exception
      # class and where the app raised it), newest first. A row opens the failure's latest exception page
      # (`/dev-dashboard/errors/<id>`), which steps through the occurrences still kept.
      module ErrorsSection
        STRIP_BUCKETS = 12
        STRIP_WIDTH   = 5.minutes

        abstract def errors : ErrorStore
        abstract def path : String

        private def render_errors : Nil
          groups = errors.groups
          card "Exceptions", "alert", meta: groups.empty? ? nil : "#{groups.sum(&.count)} in #{groups.size} group#{"s" unless groups.size == 1}" do
            if groups.empty?
              empty_state "No server errors since boot",
                "Unhandled exceptions and 5xx responses appear here, each with its exception page.", "check"
            else
              data_table "Server errors, newest first", ["Exception", "Where", "Request", "Last hour", "Seen", "Last seen", ""] do
                groups.each { |group| render_error_row(group) }
              end
            end
          end
        end

        private def render_error_row(group : ErrorStore::Group) : Nil
          url = group.latest_id.try { |id| "#{path}/errors/#{id}" }
          tr data_filter: "#{group.exception_class} #{group.message} #{group.location} #{group.request_line} #{group.route}" do
            td class: "azd-err" do
              span group.exception_class, class: "azd-err-class"
              span group.message, class: "azd-err-msg", title: group.message
            end
            td group.location || "n/a", class: "azd-mono azd-wrap"
            td do
              span class: "azd-err-req" do
                span group.status.to_s, class: "azd-http #{Status.http(group.status).css}"
                span group.request_line, class: "azd-mono azd-trunc"
              end
            end
            td { error_strip(group.times) }
            td Format.number(group.count), class: "azd-num"
            td do
              time "#{Format.uptime(Time.utc - group.last_seen)} ago", datetime: group.last_seen.to_rfc3339, class: "azd-muted"
            end
            td do
              if url
                a "Open", href: url, class: "azd-link", aria_label: "Open the exception page of #{group.exception_class}"
              else
                span "n/a", class: "azd-na"
              end
            end
          end
        end

        # Occurrences per five minutes over the last hour, oldest on the left.
        private def error_strip(times : Array(Time)) : Nil
          now = Time.utc
          counts = Array.new(STRIP_BUCKETS, 0)
          times.each do |seen|
            bucket = ((now - seen) / STRIP_WIDTH).to_i
            counts[STRIP_BUCKETS - 1 - bucket] += 1 if 0 <= bucket < STRIP_BUCKETS
          end
          high = Math.max(counts.max, 1)
          span class: "azd-strip", role: "img", aria_label: "#{counts.sum} in the last hour" do
            counts.each do |count|
              span class: count.zero? ? "azd-strip-bar is-empty" : "azd-strip-bar", style: "height: #{15 + 85 * count // high}%"
            end
          end
        end
      end
    end
  end
end
