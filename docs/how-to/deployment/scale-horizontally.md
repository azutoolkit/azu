# Scale horizontally

This guide shows you how to scale your Azu application across multiple servers.

## Stateless Design

Each process has its own memory: a second instance does not see a hash, a counter or a default `Azu.cache` entry
that the first one filled. Keep anything that must be shared in the database, or in a shared cache (see
[Redis cache](../caching/setup-redis-cache.md), which also states what works in this checkout):

```crystal
# In-memory state lives in one process only
USERS_CACHE = {} of Int64 => String

# A shared store: with the Redis store, every instance reads the same entry
Azu.cache.set("user:1", %({"id":1}))
```

Things that are per process in Azu:

- the memory cache (`CACHE_STORE=memory`, the default) and the router path cache;
- `Azu::Handler::Throttle` counters;
- the in-memory `Azu::PubSub` backend (see [WebSocket Scaling](#websocket-scaling));
- the CSRF key, unless every instance is given the same one (`Azu::Handler::CSRF.new(secret_key: ENV["CSRF_SECRET"]?)`);
- the Spark signing secret: set the same `SPARK_SECRET` everywhere.

## Session Storage

A session is a random id in a cookie that points at data in a shared store. With a shared cache:

```crystal
require "json"

class SessionStore
  def self.create(user_id : Int64) : String
    session_id = Random::Secure.hex(32)
    Azu.cache.set("session:#{session_id}", {user_id: user_id}.to_json, 24.hours)
    session_id
  end

  def self.get(session_id : String) : Int64?
    data = Azu.cache.get("session:#{session_id}")
    return unless data
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
      - CRYSTAL_ENV=production
      - DATABASE_URL=postgres://...
      - CACHE_STORE=redis
      - CACHE_REDIS_URL=redis://redis:6379/0
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
      terminationGracePeriodSeconds: 45
      containers:
        - name: app
          image: myapp:latest
          ports:
            - containerPort: 8080
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "5"]
          env:
            - name: CRYSTAL_ENV
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

## Graceful Rollouts

On `SIGTERM` an instance stops accepting connections and waits for requests in flight, up to
`SHUTDOWN_TIMEOUT` seconds (30 by default), before it exits. Set the grace period of the orchestrator above it
(`terminationGracePeriodSeconds: 45` above, `docker stop -t 40`), and let the load balancer's health check take the
instance out of rotation. Open WebSockets are sent a close frame with code 1001 when the stop begins, so clients
reconnect to another instance; see [Shut Down Gracefully](graceful-shutdown.md).

## WebSocket Scaling

`Azu::PubSub` delivers broadcasts to the subscribers in the same process. With several instances, select the Redis
backend once at boot and every instance receives every broadcast:

```crystal
Azu::PubSub.backend = Azu::PubSub::Redis.new(ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))

class NotificationChannel < Azu::Channel
  ws "/notifications"

  def on_connect
    subscribe "notifications"
  end

  def on_message(message : String)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end

# From any instance
Azu::PubSub.broadcast("notifications", {text: "Deploy finished"})
```

See [Broadcast Messages](../real-time/broadcast-messages.md), and
[Scale Real-Time Features Out](scale-out-realtime.md) for the connections, reconnect behaviour and how to
track who is online across instances with [Presence](../../reference/api/presence.md).

## Database Scaling

### Read Replicas

Define one schema per database and point read-only work at the replica:

```crystal
require "cql"
require "pg"

PrimaryDB = CQL::Schema.define(:primary, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :users do
    primary :id, Int64
    column :name, String
  end
end

ReplicaDB = CQL::Schema.define(:replica, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_REPLICA_URL"]) do
  table :users do
    primary :id, Int64
    column :name, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context PrimaryDB, :users

  property name : String

  def initialize(@name : String)
  end
end

class ReadOnlyUser
  include CQL::ActiveRecord::Model(Int64)
  db_context ReplicaDB, :users

  property name : String

  def initialize(@name : String)
  end
end
```

A replica lags behind the primary, so read your own writes from the primary.

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

The memory cache is per process. Select the Redis store through the environment, and read
[Redis cache](../caching/setup-redis-cache.md) for what the store does in this checkout:

```bash
CACHE_STORE=redis
CACHE_REDIS_URL=redis://redis.example.com:6379/0
```

## Monitoring at Scale

`RequestId` (part of the default stack) tags every request with an id that the `Logger` line and error pages carry.
Log the instance once at boot so a line can be traced to its host:

```crystal
module MyApp
  include Azu
end

MyApp.log.info { "instance #{ENV.fetch("HOSTNAME", "unknown")} version #{ENV.fetch("APP_VERSION", "unknown")}" }
```

## See Also

- [Configure Production](configure-production.md)
- [Deploy with Docker](deploy-with-docker.md)
