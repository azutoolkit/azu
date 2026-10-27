require "./error_store"
require "./dev_dashboard/data_provider"

module Azu
  module Dev
    # The exception page's "Performance context" panel: the failing endpoint's recent history (from the
    # performance monitor, when it records), how often this failure happened since boot (`ErrorStore`) and the
    # process memory. Its hints tell a failure that happens every time from one that started after successes.
    module ExceptionSignals
      extend self

      alias Format = Components::Dashboard::Format
      alias Panel = ExceptionPage::Panel
      alias Stat = ExceptionPage::Stat
      alias Hint = ExceptionPage::Hint
      alias Tone = ExceptionPage::Tone

      MIN_HISTORY = 3

      def panels(report : ExceptionPage::Report, store : ErrorStore = ErrorStore.instance) : Array(Panel)
        stats = [] of Stat
        hints = [] of Hint
        endpoint_history(report, stats, hints)
        occurrences(report, store, stats)
        process(stats, hints)
        [Panel.new("Performance context", "tracing", stats, hints: hints)]
      end

      private def endpoint_history(report : ExceptionPage::Report, stats : Array(Stat), hints : Array(Hint)) : Nil
        route = report.request.route
        history = route.try { |name| Dev.metrics.try(&.endpoint_stats(name)) }
        return if route.nil? || history.nil? || history.empty?

        total = history["total_requests"].to_i
        failed = history["error_requests"].to_i
        stats << Stat.new("Requests to #{route}", total.to_s)
        stats << Stat.new("Error rate", Format.percent(history["error_rate"]), failed.zero? ? Tone::Good : Tone::Warn)
        stats << Stat.new("p95 latency", Format.ms(history["p95_response_time"]))
        return if total < MIN_HISTORY

        if failed == total
          hints << Hint.new("Every recent request to #{route} failed",
            "All #{total} requests since the metrics were cleared answered with an error: the failure does not depend " \
            "on the input. Start from the first frame of the app.", Tone::Warn)
        elsif failed.zero?
          hints << Hint.new("The first failure after #{total} successful requests to #{route}",
            "It worked for other requests: compare this request's parameters and data with a successful one, or " \
            "look at what changed since.", Tone::Info)
        end
      end

      private def occurrences(report : ExceptionPage::Report, store : ErrorStore, stats : Array(Stat)) : Nil
        group = store.group(report.fingerprint)
        seen = (group.try(&.count) || 0) + (report.recorded? ? 0 : 1)
        stats << Stat.new("Times seen", seen.to_s, seen > 1 ? Tone::Warn : Tone::Info)
        group.try { |known| stats << Stat.new("First seen", "#{Format.uptime(Time.utc - known.first_seen)} ago") }
      end

      private def process(stats : Array(Stat), hints : Array(Hint)) : Nil
        stats << Stat.new("GC heap", Format.megabytes(GC.stats.heap_size))
        Components::DashboardDataProvider.rss_bytes.try { |bytes| stats << Stat.new("RSS", Format.megabytes(bytes)) }
        return unless leak_suspected?

        stats << Stat.new("Memory", "growing", Tone::Warn)
        hints << Hint.new("Memory keeps growing",
          "The memory leak detector sees the heap grow steadily: an error under memory pressure may be a symptom.", Tone::Warn)
      end

      private def leak_suspected? : Bool
        DevelopmentTools.memory_detector.analyze_leak.leak_detected?
      rescue
        false # analyze_leak raises until the first snapshot exists
      end
    end
  end
end
