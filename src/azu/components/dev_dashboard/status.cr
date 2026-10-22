module Azu
  module Components
    # Presentation vocabulary shared by every dashboard widget.
    module Dashboard
      # Traffic-light state behind every badge and meter: green = good,
      # amber = warning, red = error or latency spike, grey = neutral / n/a.
      # Declared least to most severe so sorting by value orders by severity.
      enum Status
        Idle
        Good
        Warn
        Bad

        # Latency bands: below 300 ms is good, below 1 s a warning, otherwise a spike.
        def self.latency(ms : Float64) : Status
          ms < 300 ? Good : (ms < 1000 ? Warn : Bad)
        end

        def self.http(code : Int32) : Status
          code < 400 ? Good : (code < 500 ? Warn : Bad)
        end

        # For values where higher is worse (error rate): below `warn` is good, below `bad` a warning.
        def self.ceiling(value : Float64, warn : Float64, bad : Float64) : Status
          value < warn ? Good : (value < bad ? Warn : Bad)
        end

        # For values where higher is better (cache hit rate): at or above `good` is good, at or above `warn` a warning.
        def self.floor(value : Float64, good : Float64, warn : Float64) : Status
          value >= good ? Good : (value >= warn ? Warn : Bad)
        end

        def css : String
          "is-#{to_s.downcase}"
        end

        # Picks the badge wording for each level, e.g. `status.pick("Fast", "Slow", "Spike")`;
        # a neutral status reads as the good wording.
        def pick(good : String, warn : String, bad : String) : String
          bad? ? bad : (warn? ? warn : good)
        end

        # Severity wording for insight and issue badges.
        def severity : String
          case self
          in .bad?  then "Critical"
          in .warn? then "Warning"
          in .good? then "Good"
          in .idle? then "Info"
          end
        end
      end

      # Log verbosity, most severe first. Doubles as the CSS modifier and the
      # `data-level` value the level toggles filter on.
      enum Level
        Error
        Warn
        Info
        Debug

        def css : String
          to_s.downcase
        end
      end
    end
  end
end
