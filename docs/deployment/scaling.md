# Scaling Strategies

This guide covers scaling Azu applications to handle increased load, from vertical scaling to horizontal scaling and distributed architectures.

## Scaling Overview

```mermaid
graph TB
    subgraph "Vertical Scaling"
        V1[Single Server] --> V2[More CPU/RAM]
        V2 --> V3[Better Performance]
    end

    subgraph "Horizontal Scaling"
        H1[Load Balancer] --> H2[App Instance 1]
        H1 --> H3[App Instance 2]
        H1 --> H4[App Instance 3]
        H1 --> H5[App Instance N]
    end

    subgraph "Database Scaling"
        D1[Master DB] --> D2[Read Replica 1]
        D1 --> D3[Read Replica 2]
        D1 --> D4[Read Replica 3]
    end

    subgraph "Caching Layer"
        C1[Redis Cluster] --> C2[Node 1]
        C1 --> C3[Node 2]
        C1 --> C4[Node 3]
    end

    style V1 fill:#e1f5fe
    style H1 fill:#fff3e0
    style D1 fill:#e8f5e8
    style C1 fill:#fce4ec
```

## Scaling Approaches

### Vertical Scaling (Scale Up)

Increasing the resources of a single server instance.

```crystal
# Configure for high-performance single instance
Azu.configure do |config|
  config.worker_threads = 8
  config.database_pool_size = 50
  config.cache_pool_size = 20
  config.request_timeout = 60.seconds
end
```

### Horizontal Scaling (Scale Out)

Adding more server instances to handle increased load.

```yaml
# docker-compose.scale.yml
version: "3.8"

services:
  app:
    deploy:
      replicas: 5
      resources:
        limits:
          memory: 1G
          cpus: "0.5"
        reservations:
          memory: 512M
          cpus: "0.25"
```

## Load Balancing

### Nginx Load Balancer

```nginx
# nginx.conf
upstream azu_app {
    # Round-robin load balancing
    server app1:3000;
    server app2:3000;
    server app3:3000;
    server app4:3000;
    server app5:3000;

    # Health checks
    health_check;
}

server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://azu_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Load balancing method
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
    }
}
```

### HAProxy Configuration

```haproxy
# haproxy.cfg
global
    daemon
    maxconn 4096

defaults
    mode http
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

frontend azu_frontend
    bind *:80
    default_backend azu_backend

backend azu_backend
    balance roundrobin
    option httpchk GET /health

    server app1 app1:3000 check
    server app2 app2:3000 check
    server app3 app3:3000 check
    server app4 app4:3000 check
    server app5 app5:3000 check
```

## Database Scaling

### Read Replicas

```crystal
# Database configuration with read replicas
Azu.configure do |config|
  config.database_url = "postgresql://user:pass@master:5432/app"
  config.database_read_replicas = [
    "postgresql://user:pass@replica1:5432/app",
    "postgresql://user:pass@replica2:5432/app",
    "postgresql://user:pass@replica3:5432/app"
  ]
  config.database_load_balancing = :round_robin
end
```

### Connection Pooling

```crystal
# PgBouncer configuration
Azu.configure do |config|
  config.database_pool_size = 20
  config.database_pool_timeout = 5.seconds
  config.database_statement_timeout = 30.seconds
  config.database_idle_timeout = 10.minutes
end
```

### Database Sharding

```crystal
# Database sharding configuration
Azu.configure do |config|
  config.database_shards = {
    "shard1" => "postgresql://user:pass@shard1:5432/app",
    "shard2" => "postgresql://user:pass@shard2:5432/app",
    "shard3" => "postgresql://user:pass@shard3:5432/app"
  }
  config.database_shard_key = "user_id"
end
```

## Caching Strategies

### Redis Cluster

```crystal
# Redis cluster configuration
Azu.configure do |config|
  config.redis_cluster_nodes = [
    "redis://node1:6379",
    "redis://node2:6379",
    "redis://node3:6379",
    "redis://node4:6379",
    "redis://node5:6379",
    "redis://node6:6379"
  ]
  config.redis_cluster_replicas = 1
end
```

### Cache Warming

```crystal
# Cache warming strategy
class CacheWarmer
  def self.warm_cache
    # Warm frequently accessed data
    warm_user_cache
    warm_product_cache
    warm_category_cache
  end

  private def self.warm_user_cache
    User.all.each do |user|
      Azu::Cache.set("user:#{user.id}", user.to_json, 1.hour)
    end
  end
end
```

### Cache Invalidation

```crystal
# Cache invalidation strategy
class CacheInvalidator
  def self.invalidate_user_cache(user_id)
    Azu::Cache.delete("user:#{user_id}")
    Azu::Cache.delete("user:#{user_id}:profile")
    Azu::Cache.delete("user:#{user_id}:settings")
  end
end
```

## Session Management

### Redis Sessions

```crystal
# Redis session configuration
Azu.configure do |config|
  config.session_store = :redis
  config.session_redis_url = "redis://localhost:6379/1"
  config.session_ttl = 24.hours
  config.session_cookie_secure = true
  config.session_cookie_httponly = true
end
```

### Session Clustering

```crystal
# Session clustering for multiple instances
class SessionManager
  def self.create_session(user_id)
    session_id = SecureRandom.uuid
    session_data = {
      "user_id" => user_id,
      "created_at" => Time.utc.to_s,
      "expires_at" => (Time.utc + 24.hours).to_s
    }

    Azu::Cache.set("session:#{session_id}", session_data.to_json, 24.hours)
    session_id
  end

  def self.get_session(session_id)
    session_data = Azu::Cache.get("session:#{session_id}")
    return nil unless session_data

    JSON.parse(session_data)
  end
end
```

## WebSocket Scaling

### WebSocket Load Balancing

```nginx
# WebSocket load balancing
upstream websocket_backend {
    server app1:3000;
    server app2:3000;
    server app3:3000;
}

server {
    location /ws {
        proxy_pass http://websocket_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### WebSocket Clustering

```crystal
# WebSocket clustering with Redis
class WebSocketCluster
  def self.broadcast_to_channel(channel, message)
    # Publish to Redis for other instances
    Azu::Cache.publish("websocket:#{channel}", message)
  end

  def self.handle_redis_message(channel, message)
    # Handle message from other instances
    WebSocketManager.broadcast_to_local_clients(channel, message)
  end
end
```

## Microservices Architecture

### Service Discovery

```crystal
# Service discovery configuration
Azu.configure do |config|
  config.service_registry = "consul://localhost:8500"
  config.service_name = "azu-app"
  config.service_port = 3000
  config.service_health_check = "/health"
end
```

### API Gateway

```crystal
# API Gateway configuration
class APIGateway
  def self.route_request(request)
    service = determine_service(request.path)
    forward_request(service, request)
  end

  private def self.determine_service(path)
    case path
    when /^\/api\/users/
      "user-service"
    when /^\/api\/products/
      "product-service"
    when /^\/api\/orders/
      "order-service"
    else
      "main-service"
    end
  end
end
```

## Container Orchestration

### Kubernetes Deployment

```yaml
# k8s-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azu-app
spec:
  replicas: 5
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
            - name: AZU_ENVIRONMENT
              value: "production"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: azu-secrets
                  key: database-url
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

### Kubernetes Service

```yaml
# k8s-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: azu-app-service
spec:
  selector:
    app: azu-app
  ports:
    - port: 80
      targetPort: 3000
  type: LoadBalancer
```

### Kubernetes HPA

```yaml
# k8s-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: azu-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: azu-app
  minReplicas: 3
  maxReplicas: 20
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

## Performance Monitoring

### Application Metrics

```crystal
# Performance monitoring
class PerformanceMonitor
  def self.track_request_time(endpoint, duration)
    Azu::Cache.increment("metrics:request_time:#{endpoint}", duration)
  end

  def self.track_memory_usage
    memory_usage = System.memory_usage
    Azu::Cache.set("metrics:memory_usage", memory_usage.to_s, 1.minute)
  end

  def self.track_database_queries
    Azu::Cache.increment("metrics:database_queries")
  end
end
```

### Prometheus Metrics

```crystal
# Prometheus metrics endpoint
struct MetricsEndpoint
  include Azu::Endpoint

  get "/metrics"

  def call
    metrics = {
      "http_requests_total" => get_request_count,
      "http_request_duration_seconds" => get_request_duration,
      "memory_usage_bytes" => get_memory_usage,
      "database_connections_active" => get_active_connections
    }

    response.header("Content-Type", "text/plain")
    response.body(format_prometheus_metrics(metrics))
  end
end
```

## Auto-scaling

### CPU-based Scaling

```yaml
# CPU-based auto-scaling
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: azu-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: azu-app
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Custom Metrics Scaling

```yaml
# Custom metrics auto-scaling
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: azu-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: azu-app
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "100"
```

## Disaster Recovery

### Multi-region Deployment

```yaml
# Multi-region deployment
apiVersion: v1
kind: ConfigMap
metadata:
  name: azu-app-config
data:
  primary_region: "us-east-1"
  backup_region: "us-west-2"
  failover_threshold: "5"
```

### Backup Strategy

```crystal
# Automated backup strategy
class BackupManager
  def self.create_backup
    timestamp = Time.utc.to_s("%Y%m%d_%H%M%S")

    # Database backup
    create_database_backup(timestamp)

    # Application backup
    create_application_backup(timestamp)

    # Upload to cloud storage
    upload_to_cloud_storage(timestamp)
  end

  private def self.create_database_backup(timestamp)
    system("pg_dump app_prod > backup_#{timestamp}.sql")
  end

  private def self.create_application_backup(timestamp)
    system("tar -czf app_backup_#{timestamp}.tar.gz /var/www/azu-app")
  end
end
```

## Cost Optimization

### Resource Optimization

```yaml
# Resource optimization
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azu-app
spec:
  template:
    spec:
      containers:
        - name: azu-app
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
```

### Spot Instances

```yaml
# Spot instances for cost savings
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azu-app
spec:
  template:
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: "spot"
      tolerations:
        - key: "spot"
          operator: "Equal"
          value: "true"
          effect: "NoSchedule"
```

## Next Steps

- Learn about [Production Deployment](production.md)
- Explore [Docker Deployment](docker.md)
- Understand [Monitoring and Alerting](monitoring.md)
- See [Security Best Practices](security.md)
