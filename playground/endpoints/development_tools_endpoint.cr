require "../../src/azu"

module ExampleApp
  # Example endpoint that demonstrates development tools integration
  # This endpoint can generate test data for the dashboard
  struct DevelopmentToolsEndpoint
    include Azu::Endpoint(DevelopmentToolsRequest, DevelopmentToolsResponse)

    get "/dev-tools"

    def call : DevelopmentToolsResponse
      action = development_tools_request.action

      case action
      when "generate_test_data"
        generate_test_data
        DevelopmentToolsResponse.new("✅ Test data generated successfully!")
      when "clear_metrics"
        clear_metrics
        DevelopmentToolsResponse.new("🗑️ All metrics cleared!")
      when "simulate_errors"
        simulate_errors
        DevelopmentToolsResponse.new("⚠️ Error simulation completed!")
      when "cache_test"
        run_cache_test
        DevelopmentToolsResponse.new("💾 Cache test completed!")
      when "component_test"
        run_component_test
        DevelopmentToolsResponse.new("🧩 Component test completed!")
      else
        DevelopmentToolsResponse.new("🛠️ Development Tools Endpoint - Available actions: generate_test_data, clear_metrics, simulate_errors, cache_test, component_test")
      end
    end

    private def development_tools_request : DevelopmentToolsRequest
      if json = params.json
        DevelopmentToolsRequest.from_json json
      else
        DevelopmentToolsRequest.from_query params.to_query
      end
    end

    private def generate_test_data
      # Get the performance monitor from config
      if monitor = ExampleApp::CONFIG.performance_monitor
        metrics = monitor.metrics

        # Generate some fake request metrics
        20.times do |i|
          endpoint_name = ["UserEndpoint", "PostEndpoint", "AuthEndpoint", "AdminEndpoint"].sample
          method = ["GET", "POST", "PUT", "DELETE"].sample
          path = ["/users", "/posts", "/auth/login", "/admin/dashboard"].sample

          # Simulate various response times
          processing_time = case i % 4
                            when 0 then Random.rand(10..50).to_f    # Fast requests
                            when 1 then Random.rand(50..200).to_f   # Normal requests
                            when 2 then Random.rand(200..500).to_f  # Slow requests
                            else        Random.rand(500..2000).to_f # Very slow requests
                            end

          memory_before = Random.rand(100_000_000..200_000_000).to_i64
          memory_after = memory_before + Random.rand(1_000_000..10_000_000).to_i64

          # Mix of successful and error responses
          status_code = case i % 10
                        when 0, 1 then 400 + Random.rand(4) # 4xx errors
                        when 2    then 500 + Random.rand(4) # 5xx errors
                        else           200                  # Success
                        end

          metrics.record_request(
            endpoint: endpoint_name,
            method: method,
            path: path,
            processing_time: processing_time,
            memory_before: memory_before,
            memory_after: memory_after,
            status_code: status_code,
            request_id: "req_#{Random::Secure.hex(8)}"
          )
        end

        # Generate cache metrics
        ["get", "set", "delete", "exists"].each do |operation|
          5.times do
            key = "test_key_#{Random.rand(100)}"
            store_type = ["memory", "redis"].sample
            processing_time = Random.rand(0.5..5.0)
            hit = operation == "get" ? Random.rand < 0.7 : nil # 70% hit rate

            metrics.record_cache(
              key: key,
              operation: operation,
              store_type: store_type,
              processing_time: processing_time,
              hit: hit,
              key_size: key.bytesize,
              value_size: operation == "set" ? Random.rand(100..1000) : nil
            )
          end
        end

        # Generate component metrics
        ["UserComponent", "PostComponent", "NavigationComponent"].each do |component_type|
          3.times do |i|
            component_id = "#{component_type}_#{Random::Secure.hex(4)}"

            # Mount event
            metrics.record_component(
              component_id: component_id,
              component_type: component_type,
              event: "mount",
              processing_time: Random.rand(1.0..10.0),
              memory_before: Random.rand(50_000_000..100_000_000).to_i64,
              memory_after: Random.rand(100_000_000..150_000_000).to_i64,
              age_at_event: Time::Span.new(seconds: 0)
            )

            # Some refresh events
            Random.rand(1..5).times do
              metrics.record_component(
                component_id: component_id,
                component_type: component_type,
                event: "refresh",
                processing_time: Random.rand(0.5..3.0),
                age_at_event: Time::Span.new(seconds: Random.rand(10..300))
              )
            end

            # Unmount event (some components)
            if Random.rand < 0.3
              metrics.record_component(
                component_id: component_id,
                component_type: component_type,
                event: "unmount",
                processing_time: Random.rand(0.5..2.0),
                age_at_event: Time::Span.new(seconds: Random.rand(60..600))
              )
            end
          end
        end
      end
    end

    private def clear_metrics
      if monitor = ExampleApp::CONFIG.performance_monitor
        monitor.clear_metrics
      end
    end

    private def simulate_errors
      if monitor = ExampleApp::CONFIG.performance_monitor
        metrics = monitor.metrics

        # Generate some error scenarios
        error_scenarios = [
          {endpoint: "AuthEndpoint", method: "POST", path: "/auth/login", status: 401},
          {endpoint: "UserEndpoint", method: "GET", path: "/users/999", status: 404},
          {endpoint: "AdminEndpoint", method: "GET", path: "/admin/secret", status: 403},
          {endpoint: "DatabaseEndpoint", method: "POST", path: "/data/process", status: 500},
          {endpoint: "PaymentEndpoint", method: "POST", path: "/payments/charge", status: 502},
        ]

        error_scenarios.each do |scenario|
          metrics.record_request(
            endpoint: scenario[:endpoint].as(String),
            method: scenario[:method].as(String),
            path: scenario[:path].as(String),
            processing_time: Random.rand(100..1000).to_f,
            memory_before: Random.rand(100_000_000..200_000_000).to_i64,
            memory_after: Random.rand(200_000_000..300_000_000).to_i64,
            status_code: scenario[:status].as(Int32),
            request_id: "error_req_#{Random::Secure.hex(8)}"
          )
        end
      end
    end

    private def run_cache_test
      if monitor = ExampleApp::CONFIG.performance_monitor
        metrics = monitor.metrics

        # Simulate a cache workload with mixed operations
        operations = [
          {op: "get", hit_rate: 0.8},
          {op: "set", hit_rate: nil},
          {op: "delete", hit_rate: nil},
        ]

        operations.each do |operation|
          10.times do
            key = "cache_test_#{Random.rand(50)}"
            hit = operation[:hit_rate] ? Random.rand < operation[:hit_rate].not_nil! : nil

            metrics.record_cache(
              key: key,
              operation: operation[:op].as(String),
              store_type: "memory",
              processing_time: Random.rand(0.1..2.0),
              hit: hit,
              key_size: key.bytesize,
              value_size: operation[:op] == "set" ? Random.rand(50..500) : nil
            )
          end
        end
      end
    end

    private def run_component_test
      if monitor = ExampleApp::CONFIG.performance_monitor
        metrics = monitor.metrics

        # Simulate component lifecycle events
        component_types = ["TestComponent", "DemoComponent", "SampleComponent"]

        component_types.each do |component_type|
          component_id = "#{component_type}_#{Random::Secure.hex(6)}"

          # Mount
          metrics.record_component(
            component_id: component_id,
            component_type: component_type,
            event: "mount",
            processing_time: Random.rand(2.0..8.0),
            memory_before: Random.rand(80_000_000..120_000_000).to_i64,
            memory_after: Random.rand(120_000_000..160_000_000).to_i64
          )

          # Multiple refresh events
          Random.rand(3..8).times do |i|
            metrics.record_component(
              component_id: component_id,
              component_type: component_type,
              event: "refresh",
              processing_time: Random.rand(0.5..2.5),
              age_at_event: Time::Span.new(seconds: i * 10 + Random.rand(10))
            )
          end
        end
      end
    end
  end
end
