# Redis sessions and error handling

This runnable example uses the real session shard with encrypted Redis sessions, a connection pool,
session-backed CSRF and an inner error handler. The session dependency is pinned to the commit used
in the deployment exercise (its manifest says 1.1.0); no published 1.1.0 tag is assumed.

```sh
cd playground/redis_sessions
shards install --frozen
crystal spec -Dsession_spec
shards build app
```

Tests need Redis (`REDIS_HOST`, `REDIS_PORT`, optional `REDIS_DATABASE` and `REDIS_PASSWORD`). They create
random keys/secrets and remove only their own session records. CI runs them against Redis 7.

To run the app, supply `SESSION_SECRET` and `CSRF_SECRET` through your deployment's secret management,
set `CRYSTAL_ENV=production`, and run `bin/app` behind your HTTPS proxy. Configure `HOST`, `PORT` and
`TRUSTED_PROXIES` for that topology. Cookies remain Secure and HttpOnly. The example Redis pool uses a
plain Redis connection: provide a protected transport/network suitable for your deployment.

`GET /csrf` issues a token, `POST /visits` accepts that token in `X-CSRF-TOKEN`, and `GET /session` shows
the counter. `GET /failure` deliberately returns a sanitized 500; the session must survive it. This
demonstrates session persistence, not a login or authorization implementation. Remove the failure route
from an application before deployment.

The order is: default outer error/security handlers → session handler → inner Rescuer → CSRF → routes.
The inner Rescuer renders endpoint errors while the session is still active; the outer handler covers
errors entering the session middleware. A single unpooled Redis connection is not safe for overlapping
operations. Pool size 20 and a one-second checkout timeout are example values to size for your workload.
