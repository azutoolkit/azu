require "../../src/azu"

module ExampleApp
  # Example endpoint that demonstrates development tools integration
  # This endpoint can generate test data for the dashboard
  struct DevelopmentToolsEndpoint
    include Azu::Endpoint(DevelopmentToolsRequest, DevelopmentToolsResponse)

    get "/dev-tools"

    def call : DevelopmentToolsResponse
      action = development_tools_request.action

      puts "DevelopmentToolsEndpoint received action: #{action}"

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
      when "database_test"
        run_database_test
        DevelopmentToolsResponse.new("🗄️ Database test completed!")
      else
        DevelopmentToolsResponse.new("🛠️ Development Tools Endpoint - Available actions: generate_test_data, clear_metrics, simulate_errors, cache_test, component_test, database_test")
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
          3.times do |_|
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
      # Use the actual cache system to generate real metrics
      cache = ExampleApp::CONFIG.cache

      # Simulate a realistic cache workload
      10.times do |i|
        # Cache some user data (simulate cache hits and misses)
        user_key = "user:#{Random.rand(20)}"
        user_data = "user_data_#{i}_#{Random.rand(1000)}"

        # Try to get first (might miss)
        cache.get(user_key)

        # Set some data
        cache.set(user_key, user_data, ttl: Random.rand(60..3600).seconds)

        # Get it again (should hit)
        cache.get(user_key)
      end

      # Simulate some session data
      5.times do |i|
        session_key = "session:#{Random.rand(10)}"
        session_data = "session_#{i}_#{Time.utc.to_unix}"

        cache.set(session_key, session_data, ttl: 30.minutes)
        cache.exists?(session_key)
      end

      # Simulate some cache deletions
      3.times do
        old_key = "user:#{Random.rand(20)}"
        cache.delete(old_key)
      end

      # Test counter operations
      2.times do
        counter_key = "counter:#{Random.rand(5)}"
        cache.increment(counter_key)
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

    private def run_database_test
      {% if @top_level.has_constant?("CQL") %}
        # Simulate various query patterns using CQL's performance monitoring
        simulate_query_patterns
        simulate_n_plus_one_pattern
        simulate_slow_queries
      {% else %}
        # Fallback: generate mock database metrics via Azu's metrics system
        generate_mock_database_metrics
      {% end %}
    end

    {% if @top_level.has_constant?("CQL") %}
      private def simulate_query_patterns
        queries = [
          {sql: "SELECT * FROM users WHERE id = ?", params: ["1"] of DB::Any, time_ms: 5.0},
          {sql: "SELECT * FROM posts WHERE user_id = ?", params: ["1"] of DB::Any, time_ms: 12.0},
          {sql: "INSERT INTO logs (message, created_at) VALUES (?, ?)", params: ["test", Time.utc.to_s] of DB::Any, time_ms: 3.0},
          {sql: "UPDATE users SET last_seen = ? WHERE id = ?", params: [Time.utc.to_s, "1"] of DB::Any, time_ms: 8.0},
          {sql: "SELECT COUNT(*) FROM sessions WHERE active = ?", params: ["true"] of DB::Any, time_ms: 2.0},
          {sql: "DELETE FROM expired_tokens WHERE expires_at < ?", params: [Time.utc.to_s] of DB::Any, time_ms: 4.0},
          {sql: "SELECT u.*, p.title FROM users u JOIN posts p ON u.id = p.user_id WHERE u.active = ?", params: ["true"] of DB::Any, time_ms: 25.0},
        ]

        queries.each do |q|
          CQL::Performance.after_query(q[:sql], q[:params], Time::Span.new(nanoseconds: (q[:time_ms] * 1_000_000).to_i64), Random.rand(1_i64..10_i64))
        end
      end

      private def simulate_n_plus_one_pattern
        # Set context for N+1 detection
        CQL::Performance.monitor.set_context(endpoint: "UserEndpoint#index")

        # First query fetches all users
        CQL::Performance.after_query(
          "SELECT * FROM users LIMIT 10",
          [] of DB::Any,
          15.milliseconds,
          10_i64
        )

        # Then individual queries for each user's posts (N+1 pattern!)
        10.times do |i|
          CQL::Performance.after_query(
            "SELECT * FROM posts WHERE user_id = ?",
            [(i + 1).to_s] of DB::Any,
            Time::Span.new(nanoseconds: (Random.rand(2.0..8.0) * 1_000_000).to_i64),
            Random.rand(0_i64..5_i64)
          )
        end

        # Clear context
        CQL::Performance.monitor.set_context(endpoint: nil)
      end

      private def simulate_slow_queries
        slow_queries = [
          {sql: "SELECT * FROM large_table WHERE unindexed_column LIKE ?", time_ms: 250.0},
          {sql: "SELECT o.*, p.*, c.* FROM orders o JOIN products p ON o.product_id = p.id JOIN categories c ON p.category_id = c.id WHERE o.status = ?", time_ms: 450.0},
          {sql: "SELECT DATE(created_at), COUNT(*) FROM analytics GROUP BY DATE(created_at) ORDER BY 1 DESC", time_ms: 1200.0},
          {sql: "SELECT * FROM audit_logs WHERE action IN (?, ?, ?) AND created_at > ?", time_ms: 350.0},
        ]

        slow_queries.each do |q|
          params : Array(DB::Any) = case q[:sql]
          when /LIKE/      then ["%search_term%"] of DB::Any
          when /status =/  then ["pending"] of DB::Any
          when /action IN/ then ["create", "update", "delete", (Time.utc - 7.days).to_s] of DB::Any
          else                  [] of DB::Any
          end
          CQL::Performance.after_query(q[:sql], params, Time::Span.new(nanoseconds: (q[:time_ms] * 1_000_000).to_i64), Random.rand(100_i64..1000_i64))
        end
      end
    {% end %}

    private def generate_mock_database_metrics
      # Fallback when CQL is not available - use Azu's performance metrics
      if monitor = ExampleApp::CONFIG.performance_monitor
        metrics = monitor.metrics

        # Generate mock database-like request patterns
        db_endpoints = ["QueryEndpoint", "ReportEndpoint", "AnalyticsEndpoint"]

        db_endpoints.each do |endpoint|
          5.times do |i|
            processing_time = case i % 3
                              when 0 then Random.rand(5..50).to_f    # Fast queries
                              when 1 then Random.rand(50..200).to_f  # Normal queries
                              else        Random.rand(200..500).to_f # Slow queries
                              end

            metrics.record_request(
              endpoint: endpoint,
              method: "GET",
              path: "/api/data/#{endpoint.downcase}",
              processing_time: processing_time,
              memory_before: Random.rand(100_000_000..150_000_000).to_i64,
              memory_after: Random.rand(150_000_000..200_000_000).to_i64,
              status_code: 200,
              request_id: "db_req_#{Random::Secure.hex(8)}"
            )
          end
        end
      end
    end
  end
end
