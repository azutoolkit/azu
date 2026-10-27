module Azu
  class ExceptionPage
    # How much a hint or a value matters, most severe first; it picks the colour it is shown in.
    enum Tone
      Bad
      Warn
      Info
      Good

      def css : String
        case self
        in .bad?  then "is-bad"
        in .warn? then "is-warn"
        in .info? then "is-idle"
        in .good? then "is-good"
        end
      end
    end

    # One "likely cause" of the exception: what to look at, and why.
    record Hint, title : String, detail : String, tone : Tone = Tone::Warn do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "title", title
          json.field "detail", detail
          json.field "severity", tone.bad? ? "error" : tone.to_s.downcase
        end
      end
    end

    # A labelled value of a panel, such as `Queries: 14`.
    record Stat, label : String, value : String, tone : Tone = Tone::Info do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "label", label
          json.field "value", value
          json.field "tone", tone.to_s.downcase
        end
      end
    end

    # A group of signals recorded around the failing request (its queries, its endpoint's history, the process
    # memory), contributed by a provider registered with `ExceptionPage.on_panels`. `hints` join the page's likely
    # causes; `rows` is a table under `columns`.
    class Panel
      getter title : String
      getter icon : String
      getter stats : Array(Stat)
      getter columns : Array(String)
      getter rows : Array(Array(String))
      getter hints : Array(Hint)
      getter note : String?

      def initialize(@title, @icon = "overview", @stats = [] of Stat, @columns = [] of String,
                     @rows = [] of Array(String), @hints = [] of Hint, @note = nil)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "title", title
          json.field "stats", stats
          unless rows.empty?
            json.field "rows" do
              json.array do
                rows.each { |row| json.object { columns.each_with_index { |column, index| json.field column, row[index]? } } }
              end
            end
          end
          json.field "note", note if note
        end
      end
    end
  end
end
