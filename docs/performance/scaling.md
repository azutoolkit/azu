# Scaling Patterns

Comprehensive guide to scaling Azu applications from single instances to distributed systems.

## Overview

Azu applications can scale both vertically (single instance) and horizontally (multiple instances). This guide covers patterns and strategies for building scalable applications that can handle increasing load.

## Vertical Scaling

### Single Instance Optimization

```crystal
# Vertical scaling configuration
CONFIG.vertical_scaling = {
  # CPU optimization
  workers: System.cpu_count,
  thread_pool_size: System.cpu_count * 2,

  # Memory optimization
  heap_size: "2G",
  gc_interval: 100,

  # I/O optimization
  backlog: 2048,
  tcp_nodelay: true
}
```

### Resource Optimization

```crystal
# Resource-optimized endpoint
struct ResourceOptimizedEndpoint
  include Endpoint(ResourceRequest, ResourceResponse)

  def call : ResourceResponse
    # Use connection pooling
    connection = connection_pool.checkout

    begin
      result = process_with_connection(connection, @request)
      ResourceResponse.new(result)
    ensure
      connection_pool.checkin(connection)
    end
  end
end
```

## Horizontal Scaling

### Load Balancing

```crystal
# Load balancer configuration
CONFIG.load_balancer = {
  algorithm: "round_robin", # or "least_connections", "ip_hash"
  health_check_interval: 30.seconds,
  health_check_path: "/health",
  session_sticky: true
}

# Health check endpoint
struct HealthCheckEndpoint
  include Endpoint(HealthRequest, HealthResponse)

  get "/health"

  def call : HealthResponse
    # Check application health
    health_status = {
      status: "healthy",
      timestamp: Time.utc,
      uptime: System.uptime,
      memory_usage: GC.stats.total_allocated,
      active_connections: connection_count
    }

    HealthResponse.new(health_status)
  end
end
```

### Session Management

```crystal
# Distributed session management
class DistributedSession
  include Session::Store

  def initialize(@redis_client : Redis::Client)
  end

  def get(session_id : String) : Session::Data?
    data = @redis_client.get("session:#{session_id}")
    Session::Data.from_json(data) if data
  end

  def set(session_id : String, data : Session::Data, ttl : Time::Span = 1.hour)
    @redis_client.setex("session:#{session_id}", ttl.total_seconds.to_i, data.to_json)
  end

  def delete(session_id : String)
    @redis_client.del("session:#{session_id}")
  end
end
```

## Database Scaling

### Read Replicas

```crystal
# Read replica configuration
CONFIG.database = {
  primary: {
    url: "postgresql://primary:5432/app",
    pool_size: 10
  },
  replicas: [
    {
      url: "postgresql://replica1:5432/app",
      pool_size: 5
    },
    {
      url: "postgresql://replica2:5432/app",
      pool_size: 5
    }
  ]
}

# Read replica routing
class ReadReplicaRouter
  @replicas = [] of Database::Connection
  @current_replica = 0

  def get_read_connection : Database::Connection
    @current_replica = (@current_replica + 1) % @replicas.size
    @replicas[@current_replica]
  end
end
```

### Database Sharding

```crystal
# Database sharding strategy
class ShardedDatabase
  @shards = {} of Int32 => Database::Connection

  def initialize
    # Initialize shard connections
    CONFIG.database.shards.each do |shard_id, config|
      @shards[shard_id] = Database::Connection.new(config.url)
    end
  end

  def get_shard(user_id : Int32) : Database::Connection
    shard_id = user_id % @shards.size
    @shards[shard_id]
  end
end

# Sharded endpoint
struct ShardedEndpoint
  include Endpoint(ShardedRequest, ShardedResponse)

  def call : ShardedResponse
    user_id = @request.user_id
    shard = sharded_database.get_shard(user_id)

    # Use appropriate shard for user data
    user_data = shard.query_one("SELECT * FROM users WHERE id = ?", user_id)

    ShardedResponse.new(user_data)
  end
end
```

## Caching Strategies

### Distributed Caching

```crystal
# Redis-based distributed cache
class DistributedCache
  @redis = Redis::Client.new(CONFIG.redis_url)

  def get(key : String) : String?
    @redis.get(key)
  end

  def set(key : String, value : String, ttl : Time::Span = 1.hour)
    @redis.setex(key, ttl.total_seconds.to_i, value)
  end

  def invalidate(pattern : String)
    keys = @redis.keys(pattern)
    @redis.del(keys) if keys.any?
  end
end

# Cached endpoint with distributed cache
struct DistributedCachedEndpoint
  include Endpoint(CacheRequest, CacheResponse)

  def call : CacheResponse
    cache_key = "user:#{@request.user_id}"

    if cached = distributed_cache.get(cache_key)
      return CacheResponse.from_cache(cached)
    end

    # Generate fresh data
    user_data = fetch_user_data(@request.user_id)

    # Cache in distributed store
    distributed_cache.set(cache_key, user_data.to_json)

    CacheResponse.new(user_data)
  end
end
```

### Cache Invalidation

```crystal
# Cache invalidation strategy
class CacheInvalidator
  @redis = Redis::Client.new(CONFIG.redis_url)

  def invalidate_user(user_id : Int32)
    # Invalidate user-specific cache
    @redis.del("user:#{user_id}")
    @redis.del("user_posts:#{user_id}")
    @redis.del("user_profile:#{user_id}")
  end

  def invalidate_pattern(pattern : String)
    keys = @redis.keys(pattern)
    @redis.del(keys) if keys.any?
  end
end
```

## Message Queues

### Background Job Processing

```crystal
# Message queue integration
class JobProcessor
  @queue = Redis::Client.new(CONFIG.redis_url)

  def enqueue(job_type : String, data : Hash)
    job = {
      id: generate_job_id,
      type: job_type,
      data: data,
      created_at: Time.utc
    }

    @queue.lpush("jobs:#{job_type}", job.to_json)
  end

  def process_jobs
    spawn do
      loop do
        if job_data = @queue.brpop("jobs:email", timeout: 1)
          job = Job.from_json(job_data[1])
          process_job(job)
        end
      end
    end
  end
end

# Job processing endpoint
struct JobEndpoint
  include Endpoint(JobRequest, JobResponse)

  def call : JobResponse
    # Enqueue background job
    job_processor.enqueue("email", {
      to: @request.email,
      subject: @request.subject,
      body: @request.body
    })

    JobResponse.new(job_id: generate_job_id)
  end
end
```

## Microservices Architecture

### Service Discovery

```crystal
# Service discovery with Consul
class ServiceRegistry
  @consul = Consul::Client.new(CONFIG.consul_url)

  def register_service(name : String, address : String, port : Int32)
    @consul.agent.service.register(
      name: name,
      address: address,
      port: port,
      check: {
        http: "http://#{address}:#{port}/health",
        interval: "30s"
      }
    )
  end

  def discover_service(name : String) : Array(ServiceInstance)
    services = @consul.catalog.service(name)
    services.map { |s| ServiceInstance.new(s.address, s.port) }
  end
end
```

### API Gateway

```crystal
# API gateway for microservices
struct ApiGatewayEndpoint
  include Endpoint(GatewayRequest, GatewayResponse)

  post "/api/*"

  def call : GatewayResponse
    # Route to appropriate microservice
    service_name = extract_service_name(@request.path)
    service_instances = service_registry.discover_service(service_name)

    # Load balance between instances
    instance = load_balancer.select(service_instances)

    # Forward request
    response = forward_request(instance, @request)

    GatewayResponse.new(response)
  end
end
```

## Container Orchestration

### Docker Configuration

```dockerfile
# Dockerfile for Azu application
FROM crystallang/crystal:1.16-alpine

WORKDIR /app

# Install dependencies
COPY shard.yml shard.lock ./
RUN shards install

# Copy source code
COPY . .

# Build application
RUN crystal build --release src/app.cr

# Expose port
EXPOSE 3000

# Run application
CMD ["./app"]
```

### Kubernetes Deployment

```yaml
# kubernetes/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azu-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: azu-app
  template:
    metadata:
      labels:
        app: azu-app
    spec:
      containers:
        - name: azu-app
          image: azu-app:latest
          ports:
            - containerPort: 3000
          env:
            - name: ENVIRONMENT
              value: "production"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: db-secret
                  key: url
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
```

## Monitoring and Observability

### Distributed Tracing

```crystal
# Distributed tracing with OpenTelemetry
class TracingMiddleware
  include Handler

  def call(request, response)
    # Create trace span
    span = tracer.start_span("http_request", {
      "http.method" => request.method,
      "http.url" => request.path,
      "http.user_agent" => request.headers["User-Agent"]?
    })

    begin
      result = @next.call(request, response)

      # Add response metadata
      span.set_attribute("http.status_code", response.status_code)

      result
    rescue ex
      # Record error
      span.record_exception(ex)
      raise ex
    ensure
      span.end
    end
  end
end
```

### Metrics Collection

```crystal
# Prometheus metrics
class MetricsCollector
  @request_counter = Prometheus::Counter.new(
    name: "http_requests_total",
    help: "Total number of HTTP requests"
  )

  @request_duration = Prometheus::Histogram.new(
    name: "http_request_duration_seconds",
    help: "HTTP request duration in seconds"
  )

  def record_request(method : String, path : String, status : Int32, duration : Time::Span)
    @request_counter.increment(labels: {method: method, path: path, status: status.to_s})
    @request_duration.observe(duration.total_seconds, labels: {method: method, path: path})
  end
end
```

## Auto-scaling

### Horizontal Pod Autoscaler

```yaml
# kubernetes/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: azu-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: azu-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

### Custom Metrics

```crystal
# Custom metrics for auto-scaling
class CustomMetrics
  @active_connections = Atomic(Int32).new(0)
  @request_queue_size = Atomic(Int32).new(0)

  def increment_connections
    @active_connections.add(1)
  end

  def decrement_connections
    @active_connections.sub(1)
  end

  def get_connection_count : Int32
    @active_connections.get
  end

  def get_queue_size : Int32
    @request_queue_size.get
  end
end

# Metrics endpoint for HPA
struct MetricsEndpoint
  include Endpoint(MetricsRequest, MetricsResponse)

  get "/metrics"

  def call : MetricsResponse
    metrics = {
      active_connections: custom_metrics.get_connection_count,
      request_queue_size: custom_metrics.get_queue_size,
      memory_usage: GC.stats.total_allocated,
      cpu_usage: get_cpu_usage
    }

    MetricsResponse.new(metrics)
  end
end
```

## Best Practices

### 1. Start Simple

```crystal
# Start with vertical scaling
CONFIG.initial_scaling = {
  # Optimize single instance first
  workers: System.cpu_count,
  memory_limit: "1G",

  # Add monitoring
  enable_metrics: true,
  enable_tracing: true
}
```

### 2. Monitor and Measure

```crystal
# Comprehensive monitoring
class ScalingMonitor
  def should_scale_horizontally? : Bool
    cpu_usage > 70 && memory_usage > 80 && response_time > 500
  end

  def get_optimal_replica_count : Int32
    current_load = get_current_load
    target_load = 50 # 50% target utilization

    (current_load / target_load).ceil.to_i32
  end
end
```

### 3. Plan for Failure

```crystal
# Circuit breaker pattern
class CircuitBreaker
  @failure_count = Atomic(Int32).new(0)
  @last_failure_time = Atomic(Time?).new(nil)
  @state = Atomic(Symbol).new(:closed)

  def call(&block)
    case @state.get
    when :open
      raise CircuitBreakerOpenError.new
    when :half_open
      # Allow limited requests
      if @failure_count.get < 3
        execute_with_fallback(&block)
      else
        @state.set(:open)
        raise CircuitBreakerOpenError.new
      end
    when :closed
      execute_with_fallback(&block)
    end
  end
end
```

## Next Steps

- [Benchmarks](benchmarks.md) - Understand performance characteristics
- [Optimization Strategies](optimization.md) - Optimize before scaling
- [Performance Tuning](advanced/performance-tuning.md) - Advanced performance techniques

---

_Remember: Scale horizontally when you can't scale vertically anymore, and always monitor your scaling decisions._
