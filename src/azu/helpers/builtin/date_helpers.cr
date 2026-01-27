module Azu
  module Helpers
    module Builtin
      # Date and time helpers for formatting temporal values.
      #
      # ## Example
      #
      # ```jinja
      # <p>Created: {{ post.created_at | time_ago }}</p>
      # <p>Published: {{ post.published_at | date_format("%B %d, %Y") }}</p>
      # <p>Event: {{ event.date | relative_time }}</p>
      # {{ time_tag(post.created_at, format="date.long") }}
      # ```
      module DateHelpers
        def self.register : Nil
          register_time_ago
          register_date_format
          register_relative_time
          register_time_tag
          register_distance_of_time
        end

        private def self.register_time_ago : Nil
          filter = Crinja.filter(:time_ago) do
            time = Util.parse_time(target.raw)
            diff = Time.utc - time

            seconds = diff.total_seconds.abs
            past = diff.total_seconds >= 0

            result = case
                     when seconds < 60
                       "just now"
                     when seconds < 3600 # < 1 hour
                       count = (seconds / 60).to_i
                       word = count == 1 ? "minute" : "minutes"
                       past ? "#{count} #{word} ago" : "in #{count} #{word}"
                     when seconds < 86400 # < 1 day
                       count = (seconds / 3600).to_i
                       word = count == 1 ? "hour" : "hours"
                       past ? "#{count} #{word} ago" : "in #{count} #{word}"
                     when seconds < 604800 # < 1 week
                       count = (seconds / 86400).to_i
                       word = count == 1 ? "day" : "days"
                       past ? "#{count} #{word} ago" : "in #{count} #{word}"
                     when seconds < 2592000 # < 30 days
                       count = (seconds / 604800).to_i
                       word = count == 1 ? "week" : "weeks"
                       past ? "#{count} #{word} ago" : "in #{count} #{word}"
                     when seconds < 31536000 # < 1 year
                       count = (seconds / 2592000).to_i
                       word = count == 1 ? "month" : "months"
                       past ? "#{count} #{word} ago" : "in #{count} #{word}"
                     else
                       count = (seconds / 31536000).to_i
                       word = count == 1 ? "year" : "years"
                       past ? "#{count} #{word} ago" : "in #{count} #{word}"
                     end

            result
          end
          Registry.register_filter(:time_ago, filter)
        end

        private def self.register_date_format : Nil
          filter = Crinja.filter({format: "%B %d, %Y"}, :date_format) do
            time = Util.parse_time(target.raw)
            format = arguments["format"].to_s
            time.to_s(format)
          end
          Registry.register_filter(:date_format, filter)
        end

        private def self.register_relative_time : Nil
          filter = Crinja.filter(:relative_time) do
            time = Util.parse_time(target.raw)
            diff = time - Time.utc

            seconds = diff.total_seconds
            future = seconds >= 0
            seconds = seconds.abs

            result = case
                     when seconds < 60
                       future ? "in a moment" : "just now"
                     when seconds < 3600 # < 1 hour
                       count = (seconds / 60).to_i
                       word = count == 1 ? "minute" : "minutes"
                       future ? "in #{count} #{word}" : "#{count} #{word} ago"
                     when seconds < 86400 # < 1 day
                       count = (seconds / 3600).to_i
                       word = count == 1 ? "hour" : "hours"
                       future ? "in #{count} #{word}" : "#{count} #{word} ago"
                     when seconds < 604800 # < 1 week
                       count = (seconds / 86400).to_i
                       word = count == 1 ? "day" : "days"
                       future ? "in #{count} #{word}" : "#{count} #{word} ago"
                     when seconds < 2592000 # < 30 days
                       count = (seconds / 604800).to_i
                       word = count == 1 ? "week" : "weeks"
                       future ? "in #{count} #{word}" : "#{count} #{word} ago"
                     when seconds < 31536000 # < 1 year
                       count = (seconds / 2592000).to_i
                       word = count == 1 ? "month" : "months"
                       future ? "in #{count} #{word}" : "#{count} #{word} ago"
                     else
                       count = (seconds / 31536000).to_i
                       word = count == 1 ? "year" : "years"
                       future ? "in #{count} #{word}" : "#{count} #{word} ago"
                     end

            result
          end
          Registry.register_filter(:relative_time, filter)
        end

        private def self.register_time_tag : Nil
          func = Crinja.function({
            time:     nil,
            format:   "%B %d, %Y",
            datetime: nil,
            class:    nil,
            id:       nil,
          }, :time_tag) do
            time_val = arguments["time"]
            format = arguments["format"].to_s
            datetime_format = arguments["datetime"]
            css_class = arguments["class"]
            id = arguments["id"]

            time = if time_val.none?
                     Time.utc
                   else
                     Util.parse_time(time_val.raw)
                   end

            # Format for display
            display_text = time.to_s(format)

            # ISO 8601 format for datetime attribute
            iso_format = datetime_format.none? ? time.to_rfc3339 : time.to_s(datetime_format.to_s)

            attrs = {"datetime" => iso_format}
            attrs["class"] = css_class.to_s unless css_class.none?
            attrs["id"] = id.to_s unless id.none?

            Crinja::SafeString.new(Util.tag("time", attrs, display_text))
          end
          Registry.register_function(:time_tag, func)
        end

        private def self.register_distance_of_time : Nil
          # Filter version - takes seconds as input
          filter = Crinja.filter(:distance_of_time) do
            seconds = target.to_i.abs.to_f

            case
            when seconds < 60
              count = seconds.to_i
              count == 1 ? "1 second" : "#{count} seconds"
            when seconds < 3600
              count = (seconds / 60).to_i
              count == 1 ? "1 minute" : "#{count} minutes"
            when seconds < 86400
              count = (seconds / 3600).to_i
              count == 1 ? "1 hour" : "#{count} hours"
            when seconds < 604800
              count = (seconds / 86400).to_i
              count == 1 ? "1 day" : "#{count} days"
            when seconds < 2592000
              count = (seconds / 604800).to_i
              count == 1 ? "1 week" : "#{count} weeks"
            when seconds < 31536000
              count = (seconds / 2592000).to_i
              count == 1 ? "1 month" : "#{count} months"
            else
              count = (seconds / 31536000).to_i
              count == 1 ? "1 year" : "#{count} years"
            end
          end
          Registry.register_filter(:distance_of_time, filter)

          # Function version - takes from_time and to_time
          func = Crinja.function({
            from_time: nil,
            to_time:   nil,
          }, :distance_of_time_between) do
            from_val = arguments["from_time"]
            to_val = arguments["to_time"]

            from_time = if from_val.none?
                          Time.utc
                        else
                          Util.parse_time(from_val.raw)
                        end

            to_time = if to_val.none?
                        Time.utc
                      else
                        Util.parse_time(to_val.raw)
                      end

            diff = (to_time - from_time).abs
            seconds = diff.total_seconds

            case
            when seconds < 60
              count = seconds.to_i
              count == 1 ? "1 second" : "#{count} seconds"
            when seconds < 3600
              count = (seconds / 60).to_i
              count == 1 ? "1 minute" : "#{count} minutes"
            when seconds < 86400
              count = (seconds / 3600).to_i
              count == 1 ? "1 hour" : "#{count} hours"
            when seconds < 604800
              count = (seconds / 86400).to_i
              count == 1 ? "1 day" : "#{count} days"
            when seconds < 2592000
              count = (seconds / 604800).to_i
              count == 1 ? "1 week" : "#{count} weeks"
            when seconds < 31536000
              count = (seconds / 2592000).to_i
              count == 1 ? "1 month" : "#{count} months"
            else
              count = (seconds / 31536000).to_i
              count == 1 ? "1 year" : "#{count} years"
            end
          end
          Registry.register_function(:distance_of_time_between, func)
        end
      end
    end
  end
end
