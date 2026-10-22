require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Performance Tracing" tab: where request time goes. Latency histogram,
      # slowest requests drawn as proportional bars, per-endpoint statistics, the
      # profiler spans and the GC heap trend. Everything is derived from the
      # retained request window and the DevelopmentTools singletons.
      module TracingSection
        private abstract def provider : DashboardDataProvider

        private def render_tracing : Nil
          div class: "azd-grid azd-two" do
            render_histogram
            render_slowest_requests
          end
          render_endpoint_table
          div class: "azd-grid azd-two" do
            render_profiler_spans
            render_memory_trend
          end
        end

        private def render_histogram : Nil
          total = provider.requests.size
          card "Latency distribution", "tracing", meta: "#{Format.number(total)} requests" do
            if total.zero?
              empty_state "No requests recorded yet", "Send some traffic through the PerformanceMonitor handler.", "tracing"
            else
              buckets = provider.latency_histogram
              peak = buckets.max_of(&.count)
              ul class: "azd-bars" do
                buckets.each { |bucket| render_bucket(bucket, peak) }
              end
            end
          end
        end

        private def render_bucket(bucket : DashboardDataProvider::Bucket, peak : Int32) : Nil
          li do
            span bucket.label, class: "azd-bar-label"
            bar bucket.count * 100.0 / peak, bucket.status
            span Format.number(bucket.count), class: "azd-bar-value"
          end
        end

        private def render_slowest_requests : Nil
          slowest = provider.slowest_requests
          card "Slowest requests", "clock", meta: "newest #{Format.number(provider.requests.size)}" do
            if slowest.empty?
              empty_state "No requests recorded yet", "Slow requests are ranked here.", "clock"
            else
              ol class: "azd-bars azd-trace" do
                slowest.each { |request| render_trace(request, slowest.first.processing_time) }
              end
            end
          end
        end

        private def render_trace(request : PerformanceMetrics::RequestMetric, slowest_ms : Float64) : Nil
          li data_filter: "#{request.method} #{request.path} #{request.endpoint}" do
            span class: "azd-bar-label" do
              verb_chip request.method
              span request.path, class: "azd-trunc"
            end
            bar request.processing_time * 100.0 / {slowest_ms, 0.001}.max, Status.latency(request.processing_time)
            span Format.ms(request.processing_time), class: "azd-bar-value"
          end
        end

        # Proportional horizontal bar; the fill colour follows the status.
        private def bar(percent : Float64, status : Status) : Nil
          div class: "azd-bar", aria_hidden: "true" do
            div class: "azd-bar-fill #{status.css}", style: "width: #{percent.zero? ? 0 : percent.clamp(1.0, 100.0).round(1)}%"
          end
        end

        private def render_endpoint_table : Nil
          endpoints = provider.endpoint_stats
          card "Endpoints", "routes", meta: "slowest average first" do
            if endpoints.empty?
              empty_state "No endpoint data", "Endpoint statistics appear once requests are recorded.", "routes"
            else
              data_table "Per-endpoint latency", ["Endpoint", "Requests", "Average", "p95", "Max", "Errors"] do
                endpoints.each { |endpoint| render_endpoint_row(endpoint) }
              end
            end
          end
        end

        private def render_endpoint_row(endpoint : DashboardDataProvider::EndpointStat) : Nil
          tr data_filter: nil do
            td endpoint.name, class: "azd-mono"
            td Format.number(endpoint.count)
            td Format.ms(endpoint.avg)
            td { badge Status.latency(endpoint.p95), Format.ms(endpoint.p95) }
            td Format.ms(endpoint.max)
            td { badge Status.ceiling(endpoint.error_rate, 1.0, 5.0), Format.percent(endpoint.error_rate) }
          end
        end

        private def render_profiler_spans : Nil
          spans = provider.profiler_spans
          card "Profiler spans", "tracing", meta: "by total time" do
            if spans.empty?
              empty_state "No spans recorded", "Wrap code in Azu::DevelopmentTools.profile(\"name\") { ... } with the profiler enabled (the default in development).", "tracing"
            else
              data_table "Profiler spans", ["Span", "Calls", "Average", "Max", "Total"] do
                spans.each do |name, span_stats|
                  tr data_filter: nil do
                    td name, class: "azd-mono"
                    td span_stats["count"].to_i.to_s
                    td Format.ms(span_stats["avg_time_ms"])
                    td Format.ms(span_stats["max_time_ms"])
                    td Format.ms(span_stats["total_time_ms"])
                  end
                end
              end
            end
          end
        end

        private def render_memory_trend : Nil
          series = provider.memory_series
          card "Memory trend", "memory", meta: "GC heap" do
            if series.size < 2
              empty_state "Memory monitoring is off", "Set PERFORMANCE_MEMORY_MONITORING=true (default in development) to sample the GC heap every 30 seconds.", "memory"
            else
              facts do
                fact "Latest", "#{series.last.round(1)} MB"
                fact "Change", "#{(series.last - series.first).round(1)} MB over #{series.size} samples"
                fact("Leak check") do
                  provider.memory_leak_suspected? ? badge(Status::Warn, "Possible leak") : badge(Status::Good, "No leak detected")
                end
              end
              sparkline series, "GC heap samples (MB)"
            end
          end
        end
      end
    end
  end
end
