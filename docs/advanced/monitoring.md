# Monitoring

Comprehensive monitoring is essential for maintaining healthy, performant applications. Azu provides built-in monitoring capabilities and integrates with external monitoring tools to give you complete visibility into your application's behavior.

## What is Monitoring?

Monitoring in Azu provides:

- **Application Metrics**: Request duration, memory usage, CPU usage
- **Business Metrics**: User activity, feature usage, conversion rates
- **Infrastructure Metrics**: Server health, database performance, cache performance
- **Error Tracking**: Exception monitoring, error rates, stack traces
- **Alerting**: Proactive notifications for critical issues

## Built-in Monitoring

### Application Metrics

```crystal
module MyApp
  include Azu

  configure do |config|
    # Enable built-in monitoring
    config.monitoring.enabled = true
    config.monitoring.metrics_collection = true
    config.monitoring.health_checks = true

    # Configure metrics
    config.monitoring.metrics = {
      request_duration: true,
      memory_usage: true,
      cpu_usage: true,
      database_queries: true,
      cache_performance: true,
      websocket_connections: true
    }
  end
end
```

### Health Checks

```crystal
class HealthCheckEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::JSON)

  get "/health"

  def call : Azu::Response::JSON
    health_status = {
      status: "healthy",
      timestamp: Time.utc.to_rfc3339,
      checks: {
        database: check_database_health,
        cache: check_cache_health,
        memory: check_memory_health,
        disk: check_disk_health
      }
    }

    Azu::Response::JSON.new(health_status)
  end

  private def check_database_health : Hash(String, JSON::Any)
    begin
      User.count
      {"status" => "healthy", "response_time" => JSON::Any.new(10)}
    rescue e
      {"status" => "unhealthy", "error" => JSON::Any.new(e.message)}
    end
  end

  private def check_cache_health : Hash(String, JSON::Any)
    begin
      Azu.cache.set("health_check", "ok", ttl: 1.minute)
      result = Azu.cache.get("health_check")
      {"status" => result == "ok" ? "healthy" : "unhealthy"}
    rescue e
      {"status" => "unhealthy", "error" => JSON::Any.new(e.message)}
    end
  end

  private def check_memory_health : Hash(String, JSON::Any)
    memory_usage = get_memory_usage
    status = memory_usage < 2.gigabytes ? "healthy" : "unhealthy"
    {"status" => status, "usage" => JSON::Any.new(memory_usage)}
  end

  private def check_disk_health : Hash(String, JSON::Any)
    disk_usage = get_disk_usage
    status = disk_usage < 0.9 ? "healthy" : "unhealthy"
    {"status" => status, "usage" => JSON::Any.new(disk_usage)}
  end
end
```

## Custom Metrics

### Business Metrics

```crystal
class BusinessMetrics
  def self.record_user_registration(user_id : Int64)
    Azu.cache.increment("metrics:user_registrations")
    Azu.cache.increment("metrics:user_registrations:#{Time.utc.to_s("%Y-%m-%d")}")
    Azu.cache.set("metrics:last_user_registration", user_id, ttl: 1.day)
  end

  def self.record_user_login(user_id : Int64)
    Azu.cache.increment("metrics:user_logins")
    Azu.cache.increment("metrics:user_logins:#{Time.utc.to_s("%Y-%m-%d")}")
    Azu.cache.set("metrics:last_user_login", user_id, ttl: 1.day)
  end

  def self.record_feature_usage(feature : String, user_id : Int64)
    Azu.cache.increment("metrics:feature_usage:#{feature}")
    Azu.cache.increment("metrics:feature_usage:#{feature}:#{Time.utc.to_s("%Y-%m-%d")}")
    Azu.cache.set("metrics:last_feature_usage:#{feature}", user_id, ttl: 1.day)
  end

  def self.record_conversion(event : String, user_id : Int64)
    Azu.cache.increment("metrics:conversions:#{event}")
    Azu.cache.increment("metrics:conversions:#{event}:#{Time.utc.to_s("%Y-%m-%d")}")
    Azu.cache.set("metrics:last_conversion:#{event}", user_id, ttl: 1.day)
  end
end
```

### Performance Metrics

```crystal
class PerformanceMetrics
  def self.record_request_duration(endpoint : String, duration : Time::Span)
    duration_ms = duration.total_milliseconds

    # Record duration
    Azu.cache.increment("metrics:request_duration:#{endpoint}")
    Azu.cache.set("metrics:request_duration:#{endpoint}:last", duration_ms)

    # Update statistics
    update_duration_statistics(endpoint, duration_ms)
  end

  def self.record_memory_usage(component : String, memory : Int64)
    Azu.cache.increment("metrics:memory_usage:#{component}")
    Azu.cache.set("metrics:memory_usage:#{component}:last", memory)

    # Update peak memory
    peak_key = "metrics:memory_usage:#{component}:peak"
    if peak = Azu.cache.get(peak_key)
      if memory > peak.to_i64
        Azu.cache.set(peak_key, memory)
      end
    else
      Azu.cache.set(peak_key, memory)
    end
  end

  def self.record_database_query(query : String, duration : Time::Span)
    duration_ms = duration.total_milliseconds

    Azu.cache.increment("metrics:database_queries:#{query}")
    Azu.cache.set("metrics:database_queries:#{query}:last", duration_ms)

    # Update query statistics
    update_query_statistics(query, duration_ms)
  end

  private def self.update_duration_statistics(endpoint : String, duration_ms : Float64)
    # Update average duration
    avg_key = "metrics:request_duration:#{endpoint}:average"
    if avg = Azu.cache.get(avg_key)
      new_avg = (avg.to_f + duration_ms) / 2
      Azu.cache.set(avg_key, new_avg)
    else
      Azu.cache.set(avg_key, duration_ms)
    end
  end

  private def self.update_query_statistics(query : String, duration_ms : Float64)
    # Update query statistics
    stats_key = "metrics:database_queries:#{query}:stats"
    if stats = Azu.cache.get(stats_key)
      stats_data = JSON.parse(stats).as_h
      stats_data["total"] = JSON::Any.new(stats_data["total"].as_i + 1)
      stats_data["average"] = JSON::Any.new((stats_data["average"].as_f + duration_ms) / 2)
      Azu.cache.set(stats_key, stats_data.to_json)
    else
      Azu.cache.set(stats_key, {
        "total" => 1,
        "average" => duration_ms,
        "max" => duration_ms,
        "min" => duration_ms
      }.to_json)
    end
  end
end
```

## Error Tracking

### Exception Monitoring

```crystal
class ExceptionMonitor
  def self.record_exception(exception : Exception, context : Hash(String, JSON::Any))
    exception_id = generate_exception_id

    # Record exception details
    Azu.cache.set("exceptions:#{exception_id}", {
      message: exception.message,
      backtrace: exception.backtrace,
      context: context,
      timestamp: Time.utc.to_rfc3339
    }.to_json, ttl: 7.days)

    # Update exception statistics
    Azu.cache.increment("metrics:exceptions")
    Azu.cache.increment("metrics:exceptions:#{exception.class.name}")
    Azu.cache.increment("metrics:exceptions:#{Time.utc.to_s("%Y-%m-%d")}")

    # Send alert for critical exceptions
    if critical_exception?(exception)
      send_critical_alert(exception, context)
    end
  end

  private def self.critical_exception?(exception : Exception) : Bool
    critical_types = ["OutOfMemoryError", "StackOverflowError", "SystemExit"]
    critical_types.includes?(exception.class.name)
  end

  private def self.send_critical_alert(exception : Exception, context : Hash(String, JSON::Any))
    # Send alert via email, Slack, etc.
    Log.error { "Critical Exception: #{exception.message}" }
  end
end
```

### Error Rate Monitoring

```crystal
class ErrorRateMonitor
  def self.record_error(endpoint : String, error_type : String)
    # Record error
    Azu.cache.increment("metrics:errors:#{endpoint}")
    Azu.cache.increment("metrics:errors:#{endpoint}:#{error_type}")
    Azu.cache.increment("metrics:errors:#{Time.utc.to_s("%Y-%m-%d")}")

    # Check error rate
    check_error_rate(endpoint)
  end

  private def self.check_error_rate(endpoint : String)
    # Get error count for last hour
    error_count = Azu.cache.get("metrics:errors:#{endpoint}:#{Time.utc.to_s("%Y-%m-%d-%H")}")?.try(&.to_i) || 0

    # Get request count for last hour
    request_count = Azu.cache.get("metrics:requests:#{endpoint}:#{Time.utc.to_s("%Y-%m-%d-%H")}")?.try(&.to_i) || 0

    # Calculate error rate
    if request_count > 0
      error_rate = error_count.to_f / request_count

      # Alert if error rate is high
      if error_rate > 0.1  # 10% error rate
        send_error_rate_alert(endpoint, error_rate)
      end
    end
  end

  private def self.send_error_rate_alert(endpoint : String, error_rate : Float64)
    Log.warn { "High error rate for #{endpoint}: #{error_rate * 100}%" }
  end
end
```

## Alerting System

### Alert Configuration

```crystal
class AlertConfiguration
  def self.configure_alerts
    # Configure alert thresholds
    Azu.cache.set("alerts:request_duration:threshold", 1000.0)  # 1 second
    Azu.cache.set("alerts:memory_usage:threshold", 2.gigabytes)
    Azu.cache.set("alerts:error_rate:threshold", 0.1)  # 10%
    Azu.cache.set("alerts:disk_usage:threshold", 0.9)  # 90%

    # Configure alert channels
    Azu.cache.set("alerts:channels", {
      "email" => ["admin@example.com"],
      "slack" => ["#alerts"],
      "webhook" => ["https://hooks.slack.com/services/..."]
    }.to_json)
  end
end
```

### Alert Processing

```crystal
class AlertProcessor
  def self.process_alerts
    # Check all alert conditions
    check_request_duration_alerts
    check_memory_usage_alerts
    check_error_rate_alerts
    check_disk_usage_alerts
  end

  private def self.check_request_duration_alerts
    threshold = Azu.cache.get("alerts:request_duration:threshold")?.try(&.to_f) || 1000.0

    # Get average request duration
    avg_duration = Azu.cache.get("metrics:request_duration:average")?.try(&.to_f) || 0.0

    if avg_duration > threshold
      send_alert("High request duration", "Average request duration: #{avg_duration}ms")
    end
  end

  private def self.check_memory_usage_alerts
    threshold = Azu.cache.get("alerts:memory_usage:threshold")?.try(&.to_i64) || 2.gigabytes

    # Get current memory usage
    memory_usage = get_memory_usage

    if memory_usage > threshold
      send_alert("High memory usage", "Memory usage: #{memory_usage} bytes")
    end
  end

  private def self.check_error_rate_alerts
    threshold = Azu.cache.get("alerts:error_rate:threshold")?.try(&.to_f) || 0.1

    # Get error rate for last hour
    error_count = Azu.cache.get("metrics:errors:#{Time.utc.to_s("%Y-%m-%d-%H")}")?.try(&.to_i) || 0
    request_count = Azu.cache.get("metrics:requests:#{Time.utc.to_s("%Y-%m-%d-%H")}")?.try(&.to_i) || 0

    if request_count > 0
      error_rate = error_count.to_f / request_count

      if error_rate > threshold
        send_alert("High error rate", "Error rate: #{error_rate * 100}%")
      end
    end
  end

  private def self.check_disk_usage_alerts
    threshold = Azu.cache.get("alerts:disk_usage:threshold")?.try(&.to_f) || 0.9

    # Get disk usage
    disk_usage = get_disk_usage

    if disk_usage > threshold
      send_alert("High disk usage", "Disk usage: #{disk_usage * 100}%")
    end
  end

  private def self.send_alert(title : String, message : String)
    # Send alert to configured channels
    channels = JSON.parse(Azu.cache.get("alerts:channels") || "{}").as_h

    channels.each do |channel, config|
      case channel
      when "email"
        send_email_alert(config.as_a, title, message)
      when "slack"
        send_slack_alert(config.as_a, title, message)
      when "webhook"
        send_webhook_alert(config.as_a, title, message)
      end
    end
  end
end
```

## Dashboard

### Metrics Dashboard

```crystal
class MetricsDashboard
  def self.get_dashboard_data : Hash(String, JSON::Any)
    {
      "overview" => get_overview_metrics,
      "performance" => get_performance_metrics,
      "business" => get_business_metrics,
      "errors" => get_error_metrics,
      "infrastructure" => get_infrastructure_metrics
    }
  end

  private def self.get_overview_metrics
    {
      "uptime" => get_uptime,
      "requests_per_minute" => get_requests_per_minute,
      "active_users" => get_active_users,
      "error_rate" => get_error_rate
    }
  end

  private def self.get_performance_metrics
    {
      "request_duration" => {
        "average" => Azu.cache.get("metrics:request_duration:average")?.try(&.to_f) || 0.0,
        "max" => Azu.cache.get("metrics:request_duration:max")?.try(&.to_f) || 0.0,
        "min" => Azu.cache.get("metrics:request_duration:min")?.try(&.to_f) || 0.0
      },
      "memory_usage" => {
        "current" => Azu.cache.get("metrics:memory_usage:current")?.try(&.to_i64) || 0,
        "peak" => Azu.cache.get("metrics:memory_usage:peak")?.try(&.to_i64) || 0
      },
      "cpu_usage" => {
        "current" => Azu.cache.get("metrics:cpu_usage:current")?.try(&.to_f) || 0.0,
        "average" => Azu.cache.get("metrics:cpu_usage:average")?.try(&.to_f) || 0.0
      }
    }
  end

  private def self.get_business_metrics
    {
      "user_registrations" => {
        "today" => Azu.cache.get("metrics:user_registrations:#{Time.utc.to_s("%Y-%m-%d")}")?.try(&.to_i) || 0,
        "total" => Azu.cache.get("metrics:user_registrations")?.try(&.to_i) || 0
      },
      "user_logins" => {
        "today" => Azu.cache.get("metrics:user_logins:#{Time.utc.to_s("%Y-%m-%d")}")?.try(&.to_i) || 0,
        "total" => Azu.cache.get("metrics:user_logins")?.try(&.to_i) || 0
      },
      "feature_usage" => get_feature_usage_metrics
    }
  end

  private def self.get_error_metrics
    {
      "total_errors" => Azu.cache.get("metrics:exceptions")?.try(&.to_i) || 0,
      "errors_today" => Azu.cache.get("metrics:exceptions:#{Time.utc.to_s("%Y-%m-%d")}")?.try(&.to_i) || 0,
      "error_types" => get_error_type_metrics
    }
  end

  private def self.get_infrastructure_metrics
    {
      "database" => {
        "connection_pool" => get_database_connection_pool_metrics,
        "query_performance" => get_database_query_metrics
      },
      "cache" => {
        "hit_rate" => get_cache_hit_rate,
        "performance" => get_cache_performance_metrics
      },
      "websockets" => {
        "active_connections" => get_websocket_connection_count,
        "message_rate" => get_websocket_message_rate
      }
    }
  end
end
```

## External Monitoring Integration

### Prometheus Integration

```crystal
class PrometheusExporter
  def self.export_metrics : String
    metrics = [] of String

    # Export request duration metrics
    Azu.cache.keys("metrics:request_duration:*").each do |key|
      endpoint = key.split(":").last
      duration = Azu.cache.get(key)?.try(&.to_f) || 0.0
      metrics << "azu_request_duration_seconds{endpoint=\"#{endpoint}\"} #{duration / 1000.0}"
    end

    # Export memory usage metrics
    memory_usage = get_memory_usage
    metrics << "azu_memory_usage_bytes #{memory_usage}"

    # Export error count metrics
    error_count = Azu.cache.get("metrics:exceptions")?.try(&.to_i) || 0
    metrics << "azu_errors_total #{error_count}"

    metrics.join("\n")
  end
end
```

### Grafana Dashboard

```crystal
class GrafanaDashboard
  def self.get_dashboard_config : Hash(String, JSON::Any)
    {
      "dashboard" => {
        "title" => "Azu Application Dashboard",
        "panels" => [
          {
            "title" => "Request Duration",
            "type" => "graph",
            "targets" => [
              {
                "expr" => "azu_request_duration_seconds",
                "legendFormat" => "{{endpoint}}"
              }
            ]
          },
          {
            "title" => "Memory Usage",
            "type" => "graph",
            "targets" => [
              {
                "expr" => "azu_memory_usage_bytes",
                "legendFormat" => "Memory Usage"
              }
            ]
          },
          {
            "title" => "Error Rate",
            "type" => "graph",
            "targets" => [
              {
                "expr" => "rate(azu_errors_total[5m])",
                "legendFormat" => "Error Rate"
              }
            ]
          }
        ]
      }
    }
  end
end
```

## Best Practices

### 1. Monitor Key Metrics

```crystal
# Good: Monitor key metrics
class KeyMetrics
  def self.record_key_metrics
    record_request_duration
    record_memory_usage
    record_error_rate
    record_business_metrics
  end
end

# Avoid: Monitor everything
# Monitoring everything - can be overwhelming and expensive
```

### 2. Set Appropriate Thresholds

```crystal
# Good: Appropriate thresholds
Azu.cache.set("alerts:request_duration:threshold", 1000.0)  # 1 second
Azu.cache.set("alerts:memory_usage:threshold", 2.gigabytes)
Azu.cache.set("alerts:error_rate:threshold", 0.1)  # 10%

# Avoid: Too sensitive thresholds
Azu.cache.set("alerts:request_duration:threshold", 100.0)  # Too sensitive
Azu.cache.set("alerts:memory_usage:threshold", 1.gigabyte)  # Too sensitive
```

### 3. Use Structured Logging

```crystal
# Good: Structured logging
Log.info { "User registered: #{user.id}, email: #{user.email}" }
Log.error(exception: e) { "Database error: #{e.message}" }

# Avoid: Unstructured logging
Log.info { "User registered" }
Log.error { "Database error" }
```

### 4. Implement Health Checks

```crystal
# Good: Comprehensive health checks
class HealthCheck
  def self.comprehensive_health_check
    {
      database: check_database,
      cache: check_cache,
      memory: check_memory,
      disk: check_disk,
      external_services: check_external_services
    }
  end
end

# Avoid: Basic health checks
class HealthCheck
  def self.basic_health_check
    {status: "ok"}
  end
end
```

### 5. Monitor Business Metrics

```crystal
# Good: Business metrics
class BusinessMetrics
  def self.record_business_metrics
    record_user_registrations
    record_user_logins
    record_feature_usage
    record_conversions
  end
end

# Avoid: Only technical metrics
# Only technical metrics - missing business context
```

## Next Steps

Now that you understand monitoring:

1. **[Performance](performance.md)** - Optimize application performance
2. **[Alerting](alerting.md)** - Set up alerting systems
3. **[Dashboard](dashboard.md)** - Create monitoring dashboards
4. **[Testing](../testing.md)** - Test monitoring systems
5. **[Deployment](../deployment/production.md)** - Deploy with monitoring

---

_Monitoring in Azu provides comprehensive visibility into your application's behavior. With built-in metrics, custom monitoring, and external integrations, you can maintain healthy, performant applications with confidence._
