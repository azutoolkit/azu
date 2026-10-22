module Azu
  module Components
    module Dashboard
      # Human-readable renderings of raw metric values.
      module Format
        extend self

        def number(count : Int) : String
          count.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
        end

        def ms(value : Float64) : String
          ms_parts(value).join
        end

        # Number and unit apart, so KPI cards can style the unit separately.
        def ms_parts(value : Float64) : Tuple(String, String)
          value >= 1000 ? {(value / 1000).round(2).to_s, "s"} : {value.round(value < 10 ? 2 : 1).to_s, "ms"}
        end

        def megabytes(bytes : Int) : String
          "#{(bytes / 1024.0 / 1024.0).round(1)} MB"
        end

        def percent(value : Float64) : String
          "#{value.round(1)}%"
        end

        def uptime(span : Time::Span) : String
          if span.total_days >= 1
            "#{span.days}d #{span.hours}h"
          elsif span.total_hours >= 1
            "#{span.hours}h #{span.minutes}m"
          elsif span.total_minutes >= 1
            "#{span.minutes}m #{span.seconds}s"
          else
            "#{span.seconds}s"
          end
        end

        def clock(time : Time) : String
          time.to_s("%H:%M:%S.%L")
        end
      end
    end
  end
end
