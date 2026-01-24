# How to Scale Horizontally

This guide shows you how to scale your Azu application across multiple servers.

## Stateless Design

Ensure your application is stateless:

```crystal
# Bad: In-memory state
@@users_cache = {} of Int64 => User

# Good: External cache
Azu.cache.set("user:#{id}", user.to_json)
```

## Session Storage

Use Redis for sessions:

```crystal
class SessionStore
  def self.create(user_id : Int64) : String
    session_id = Random::Secure.hex(32)
    Azu.cache.set(
      "session:#{session_id}",
      {user_id: user_id, created_at: Time.utc}.to_json,
      expires_in: 24.hours
    )
    session_id
  end

  def self.get(session_id : String) : Int64?
    data = Azu.cache.get("session:#{session_id}")
    return nil unless data
    JSON.parse(data)["user_id"].as_i64
  end
end
```

## Load Balancer Configuration

### Nginx as Load Balancer

```nginx
upstream app_servers {
    least_conn;  # Use least connections algorithm
    server app1:8080;
    server app2:8080;
    server app3:8080;
}

server {
    listen 80;

    location / {
        proxy_pass http://app_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /health {
        proxy_pass http://app_servers;
        proxy_connect_timeout 1s;
        proxy_read_timeout 1s;
    }
}
```

### HAProxy Configuration

```haproxy
frontend http_front
    bind *:80
    default_backend app_servers

backend app_servers
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200

    server app1 app1:8080 check inter 5s fall 3 rise 2
    server app2 app2:8080 check inter 5s fall 3 rise 2
    server app3 app3:8080 check inter 5s fall 3 rise 2
```

## Docker Swarm

Scale with Docker Swarm:

```yaml
# docker-compose.swarm.yml
version: "3.8"

services:
  app:
    image: myapp:latest
    deploy:
      replicas: 3
      update_config:
        parallelism: 1
        delay: 10s
      restart_policy:
        condition: on-failure
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
    environment:
      - AZU_ENV=production
      - DATABASE_URL=postgres://...
      - REDIS_URL=redis://redis:6379/0
    networks:
      - app_network

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    deploy:
      placement:
        constraints:
          - node.role == manager
    networks:
      - app_network

  redis:
    image: redis:7-alpine
    deploy:
      replicas: 1
    networks:
      - app_network

networks:
  app_network:
    driver: overlay
```

Deploy to swarm:

```bash
docker stack deploy -c docker-compose.swarm.yml myapp
docker service scale myapp_app=5
```

## Kubernetes Deployment

```yaml
# kubernetes/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: app
          image: myapp:latest
          ports:
            - containerPort: 8080
          env:
            - name: AZU_ENV
              value: "production"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: myapp-secrets
                  key: database-url
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  selector:
    app: myapp
  ports:
    - port: 80
      targetPort: 8080
  type: LoadBalancer
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: myapp-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: myapp
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

## WebSocket Scaling

Handle WebSockets across multiple servers with Redis pub/sub:

```crystal
class ScalableNotificationChannel < Azu::Channel
  PATH = "/notifications"

  @@redis = Redis.new(url: ENV["REDIS_URL"])
  @@local_connections = [] of HTTP::WebSocket

  def on_connect
    @@local_connections << socket

    # Subscribe to Redis channel
    spawn do
      @@redis.subscribe("notifications") do |on|
        on.message do |channel, message|
          @@local_connections.each(&.send(message))
        end
      end
    end
  end

  def self.broadcast(message : String)
    # Publish to Redis - all servers receive it
    @@redis.publish("notifications", message)
  end
end
```

## Database Scaling

### Read Replicas

```crystal
module Database
  PRIMARY = CQL::Schema.define(:primary,
    adapter: CQL::Adapter::Postgres,
    uri: ENV["DATABASE_URL"]
  )

  REPLICA = CQL::Schema.define(:replica,
    adapter: CQL::Adapter::Postgres,
    uri: ENV["DATABASE_REPLICA_URL"]
  )

  def self.read
    REPLICA
  end

  def self.write
    PRIMARY
  end
end

# Usage
users = Database.read.query("SELECT * FROM users")
Database.write.exec("INSERT INTO users ...")
```

### Connection Pooling

Use PgBouncer for PostgreSQL:

```ini
# pgbouncer.ini
[databases]
myapp = host=db port=5432 dbname=myapp

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
```

## Cache Scaling

Use Redis Cluster:

```crystal
Azu.configure do |config|
  config.cache = Azu::Cache::RedisStore.new(
    url: ENV["REDIS_CLUSTER_URL"],
    cluster: true
  )
end
```

## Monitoring at Scale

Add instance identification:

```crystal
struct HealthEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/health"

  def call
    json({
      status: "healthy",
      instance: ENV.fetch("HOSTNAME", "unknown"),
      version: ENV.fetch("APP_VERSION", "unknown"),
      uptime: Process.times.real.to_i
    })
  end
end
```

## See Also

- [Configure Production](configure-production.md)
- [Deploy with Docker](deploy-with-docker.md)
