module Azu
  # :nodoc:
  struct LogFormat < Log::StaticFormatter
    getter orange_red = Colorize::ColorRGB.new(255, 140, 0)

    def run
      string " AZU ".colorize.fore(:white).back(:blue)
      string "  "
      string @entry.timestamp.to_s("%a %m/%d/%Y %I:%M:%S")
      string " ⤑  "
      string severity_colored(@entry.severity)
      string " ⤑  "
      string Log.progname.capitalize.colorize.bold
      string " ⤑  "
      message
      exception
    end

    def exception(*, before = '\n', after = nil)
      if ex = @entry.exception
        @io << before

        if ex.responds_to? :title
          @io << "   ⤑  Title: ".colorize(:light_gray)
          @io << ex.title.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :status
          @io << "   ⤑  Status: ".colorize(:light_gray)
          @io << ex.status_code.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :link
          @io << "   ⤑  Link: ".colorize(:light_gray)
          @io << ex.link.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :detail
          @io << "   ⤑  Detail: ".colorize(:light_gray)
          @io << ex.detail.colorize(:cyan)
          @io << "\n"
        end

        if ex.responds_to? :source
          @io << "   ⤑  Source: ".colorize(:light_gray)
          @io << ex.source.colorize(:cyan)
          @io << "\n"
        end

        @io << "   ⤑  Backtrace: ".colorize(:light_gray)
        ex.inspect_with_backtrace(@io).colorize(:cyan)
        @io << after
      end
    end

    private def severity_colored(severity)
      output = " #{severity} ".colorize.fore(:white)
      case severity
      when ::Log::Severity::Info                          then output.back(:green).bold
      when ::Log::Severity::Debug                         then output.back(:blue).bold
      when ::Log::Severity::Warn                          then output.back(orange_red).bold
      when ::Log::Severity::Error, ::Log::Severity::Fatal then output.back(:red).bold
      else
        output.back(:black).bold
      end
    end
  end
end
