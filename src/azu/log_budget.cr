module Azu
  # Lets a number of log lines through each second and counts the rest, so a flood of one event is not a flood of lines.
  class LogBudget
    def initialize(@per_second : Int32 = 10)
      @mutex = Mutex.new
      @window = Clock.instant
      @logged = 0
      @suppressed = 0
    end

    # {whether to write this line, how many lines the window before left out}
    def take : {Bool, Int32}
      now = Clock.instant
      @mutex.synchronize do
        summary = 0
        if now - @window >= 1.second
          summary = @suppressed
          @window = now
          @logged = 0
          @suppressed = 0
        end
        if @logged < @per_second
          @logged += 1
          {true, summary}
        else
          @suppressed += 1
          {false, summary}
        end
      end
    end
  end
end
