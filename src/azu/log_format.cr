require "colorize"
require "log"
require "benchmark"

module Azu
  module SQL
    struct Formatter < Log::StaticFormatter
      getter orange_red = Colorize::ColorRGB.new(255, 140, 0)

      def run
        entry_data = @entry.data
        @io << " AZU ".colorize.fore(:white).back(:blue)
        @io << "  "
        @io << @entry.timestamp.to_s("%a %m/%d/%Y %I:%M:%S")
        @io << " ⤑  "
        @io << severity_colored(@entry.severity)
        @io << " ⤑  "
        @io << Log.progname.capitalize.colorize.bold
        @io << " ⤑  SQL"
        @io << "\n"
        @io << SQL.colorize_query(entry_data[:query].as_s)
        @io << " \n\t" << entry_data[:args].colorize.magenta if entry_data[:args]?
        @io << "\n"
      end

      def severity_colored(severity)
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

    class_property colorize : Bool = STDOUT.tty? && STDERR.tty?

    private SQL_KEYWORDS = Set(String).new(%w(
      ADD ALL ALTER ANALYSE ANALYZE AND ANY ARRAY AS ASC ASYMMETRIC
      BEGIN BOTH BY CASE CAST CHECK COLLATE COLUMN COMMIT CONSTRAINT COUNT CREATE CROSS
      CURRENT_DATE CURRENT_ROLE CURRENT_TIME CURRENT_TIMESTAMP
      CURRENT_USER CURSOR DECLARE DEFAULT DELETE DEFERRABLE DESC
      DISTINCT DROP DO ELSE END EXCEPT EXISTS FALSE FETCH FULL FOR FOREIGN FROM GRANT
      GROUP HAVING IF IN INDEX INNER INSERT INITIALLY INTERSECT INTO JOIN LAGGING
      LEADING LIMIT LEFT LOCALTIME LOCALTIMESTAMP NATURAL NEW NOT NULL OFF OFFSET
      OLD ON ONLY OR ORDER OUTER PLACING PRIMARY REFERENCES RELEASE RETURNING
      RIGHT ROLLBACK SAVEPOINT SELECT SESSION_USER SET SOME SYMMETRIC
      TABLE THEN TO TRAILING TRIGGER TRUE UNION UNIQUE UPDATE USER USING VALUES
      WHEN WHERE WINDOW START
    ))

    def self.colorize_query(qry : String)
      return qry unless @@colorize

      o = qry.to_s.split(/([a-zA-Z0-9_]+)/).join do |word|
        if SQL_KEYWORDS.includes?(word.upcase)
          if %w(START INSERT UPDATE CREATE ALTER COMMIT SELECT FROM WHERE GROUP LEFT RIGHT JOIN).includes?(word.upcase)
            "\n\t#{word.colorize.bold.blue}"
          else
            word.colorize.bold.blue.to_s
          end
        elsif word =~ /\d+/
          word.colorize.red
        else
          word.colorize.white
        end
      end
      o.gsub(/(--.*)$/, &.colorize.dark_gray)
    end

    def self.display_mn_sec(x : Float64) : String
      mn = x.to_i / 60
      sc = x.to_i % 60

      {mn > 9 ? mn : "0#{mn}", sc > 9 ? sc : "0#{sc}"}.join("mn") + "s"
    end

    def self.display_time(x : Float64) : String
      if (x > 60)
        display_mn_sec(x)
      elsif (x > 1)
        ("%.2f" % x) + "s"
      elsif (x > 0.001)
        (1_000 * x).to_i.to_s + "ms"
      else
        (1_000_000 * x).to_i.to_s + "µs"
      end
    end
  end

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
