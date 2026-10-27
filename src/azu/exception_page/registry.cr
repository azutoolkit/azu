require "./report"

module Azu
  class ExceptionPage
    alias PanelProvider = Report -> Array(Panel)
    alias HintRule = Exception, Report -> Hint?

    @@panel_providers = [] of PanelProvider
    @@hint_rules = [] of HintRule
    @@dashboard_path : String? = nil

    # Where the dev dashboard is mounted, set by `Handler::DevDashboard`; nil hides the dashboard links.
    def self.dashboard_path : String?
      @@dashboard_path
    end

    def self.dashboard_path=(path : String?) : String?
      @@dashboard_path = path
    end

    # Adds a group of signals to every report: the block gets the report (request, frames, ids) and returns the
    # panels it has something to say in, usually none or one. Registered at require time, like
    # `Instrumentation` subscribers.
    #
    # ```
    # Azu::ExceptionPage.on_panels do |report|
    #   jobs = MyQueue.failed_since(report.timestamp - 5.minutes)
    #   next [] of Azu::ExceptionPage::Panel if jobs.zero?
    #   [Azu::ExceptionPage::Panel.new("Jobs", stats: [Azu::ExceptionPage::Stat.new("Failed (5 min)", jobs.to_s, :warn)])]
    # end
    # ```
    def self.on_panels(&block : Report -> Array(Panel)) : Nil
      @@panel_providers << block
    end

    # Adds a likely cause for exceptions of `type`: the block returns a `Hint`, or nil when it has nothing to say.
    #
    # ```
    # Azu::ExceptionPage.hint(Stripe::CardError) do |error, report|
    #   Azu::ExceptionPage::Hint.new("The card was declined", "Stripe said: #{error.code}", :info)
    # end
    # ```
    def self.hint(type : T.class, &block : T, Report -> Hint?) : Nil forall T
      @@hint_rules << ->(exception : Exception, report : Report) do
        exception.as?(T).try { |matched| block.call(matched, report) }
      end
    end

    # :nodoc:
    def self.panels_for(report : Report) : Array(Panel)
      @@panel_providers.flat_map { |provider| safely { provider.call(report) } || [] of Panel }
    end

    # :nodoc:
    #
    # The hints of the rules that match, then those of the panels; most severe first, without repeats.
    def self.hints_for(exception : Exception, report : Report) : Array(Hint)
      hints = @@hint_rules.compact_map { |rule| safely { rule.call(exception, report) } }
      hints.concat(report.panels.flat_map(&.hints))
      hints.uniq(&.title).sort_by!(&.tone.value)
    end

    # For specs: runs the block with no panel providers or hint rules beyond the ones it registers.
    def self.isolate(&)
      saved = {@@panel_providers, @@hint_rules, @@dashboard_path}
      @@panel_providers = [] of PanelProvider
      @@hint_rules = [] of HintRule
      begin
        yield
      ensure
        @@panel_providers, @@hint_rules, @@dashboard_path = saved
      end
    end

    private def self.safely(&)
      yield
    rescue ex
      Log.for("azu.exception_page").debug(exception: ex) { "Exception page provider failed" }
      nil
    end
  end
end
