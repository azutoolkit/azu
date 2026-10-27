---
description: Exactly which Azu behaviours depend on the environment, and how to set and check it.
---

# Environments

`Azu::Configuration#env` names the environment the application runs in, an `Azu::Environment` that comes with
`require "azu"`. Azu changes a small, specific set of behaviours with it; everything else is configured explicitly.
It is not a configuration profile: no log level, cache store or handler stack is chosen by the environment.

```crystal
require "azu"

Azu::Environment.values.each { |environment| puts environment }
```

## API

### Environment enum

`Azu::Environment` has eight members, in this order: `Build`, `Development`, `Test`, `Integration`, `Acceptance`,
`Pipeline`, `Staging`, `Production`.

### Via environment variable

```bash
export CRYSTAL_ENV=production
```

The name is case-insensitive (`production` and `Production` both work) and `Development` is used when the variable
is unset. An unknown name raises `ArgumentError: Unknown enum Azu::Environment value: bogus` when the configuration
is built, at `require "azu"`. The variable is `CRYSTAL_ENV`; `AZU_ENV` is not read.

### The default environment

An unset (or blank) `CRYSTAL_ENV` means `Development`, as in Rails. Because development switches debugging aids on (the
exception page with the request context, the dev dashboard where an app mounts it), the default bind address in
development is `127.0.0.1`, not `0.0.0.0`: a process that forgot its `CRYSTAL_ENV` is reachable from the machine only.

- An explicit address is always kept: `HOST=0.0.0.0` or `config.host = "0.0.0.0"` listens on every interface in any
  environment, development included.
- Every other environment keeps `0.0.0.0` unless you set one.
- The address follows `config.env` when `host` is read, so `config.env = Production` in `configure` also moves the default.
- When the environment came from the default (neither `CRYSTAL_ENV` nor `config.env=` chose it), `start` logs one INFO line:
  `CRYSTAL_ENV not set, running in development, listening on 127.0.0.1`. `Configuration#env_from_default?` answers it.
- Test, Pipeline, Build, Integration, Acceptance, Staging and Production are not development: they bind `0.0.0.0` unless a host
  is set.
- `start` warns (WARN) when the server listens on a loopback address inside a container (`/.dockerenv` or Podman's `/run/.containerenv` exists, or
  `KUBERNETES_SERVICE_HOST` is set; `Configuration#container=` overrides): connections from outside the container are
  refused, and the line names the fix, `HOST=0.0.0.0`. It does so also with `CRYSTAL_ENV=development` set explicitly. It warns
  as well when `CRYSTAL_ENV` was never set and the host is not loopback, because the development pages are then served on every
  interface.
- A container that must be reached from outside sets `CRYSTAL_ENV` and `HOST` itself, as the Dockerfile in
  [Deploying to production](../../tutorials/deploying-to-production.md) does.

### Via configuration

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.env = Azu::Environment::Staging
  end
end
```

{% hint style="info" %}
Azu does not load `.env` files on its own. Call `Azu::Env.load_all` before `require "azu"` to load them (see [Azu::Env](env.md));
a variable already in the process environment always wins over a file.
{% endhint %}

### Checking the environment

Every member has a predicate, and `in?` takes several:

```crystal
require "azu"

env = Azu::CONFIG.env

env.production?
env.development?
env.test?
env.in?(Azu::Environment::Staging, Azu::Environment::Production)
```

Inside a request, `Azu.current_config.env` is the environment of the app serving it.

## Behavior

### What depends on the environment

| Behaviour | Development | Test | Pipeline | Staging, Production | Others |
|---|---|---|---|---|---|
| `template_hot_reload?` default | on | on | on | off | off |
| Error responses of `Rescuer` carry the request context | yes | no | no | no | no |
| HTML error page | Azu's exception page | `error.html` | `error.html` | `error.html` | `error.html` |
| Spark live views need `SPARK_SECRET` | no | no | no | **yes** | no |
| Spark error frames carry the real message | yes | yes | no | no | no |
| Profiler and memory monitor (`azu/dev`) default | on | off | off | off | off |
| `Handler::DevDashboard` (`azu/dev`) serves | yes | no, passes through | no, passes through | no, passes through | no, passes through |
| Database SQL playground of the dashboard | allowed | no | no | no | no |
| Default bind host (when neither `HOST` nor `config.host` is set) | `127.0.0.1` | `0.0.0.0` | `0.0.0.0` | `0.0.0.0` | `0.0.0.0` |

Notes on the rows:

- `TEMPLATE_HOT_RELOAD=true|false` overrides the default in every environment.
- In development, `Rescuer` includes the request context (headers, params, process environment) in the error and
  HTML clients get Azu's exception page, which triages the exception (see [Debug exceptions](../../how-to/errors/debug-exceptions.md));
  JSON clients get the same triage in an `exception` member. Elsewhere the context is `null` and HTML clients get the
  `error.html` template, for an unexpected exception too: a `500` page that shows a plain sentence about the status and
  a reference id, never the exception's message.
- Spark signs its page tokens with `SPARK_SECRET`; what happens without one in each environment is on
  [Spark configuration](spark.md#the-secret).
- `Handler::DevDashboard` checks `Azu.current_config.env.development?` on every request, so the environment of the app serving
  the request decides, whatever the handler list contains. Outside development it calls the next handler (the router
  answers `404` for an unrouted `/dev-dashboard`) and never renders the dashboard or the SQL playground; building it
  there logs one `WARN`. There is no option to allow it in production. `Handler::PerformanceMonitor` answers no
  request of its own (it only records metrics), so it has nothing to gate.
- The profiler and memory monitor exist after `require "azu/dev"`; `PERFORMANCE_PROFILING` and
  `PERFORMANCE_MEMORY_MONITORING` set them explicitly.
- The dashboard's SQL playground is further limited to loopback clients and `config.database.playground?`.

Everything else, including the log level, the cache store, the port and the handler stack, is independent of the
environment. Azu sets no log level and no cache store per environment; the configuration below does.

### Development

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.env = Azu::Environment::Development
    config.template_hot_reload = true
  end
end

Azu.setup_logging # Azu's log format at Debug
```

Add `require "azu/dev"` and `Azu::Handler::DevDashboard.new` to the handlers to get the dashboard (see the
[database dashboard](../database-dashboard.md)). The dashboard serves in development only: in any other environment it
passes every request to the next handler and building one logs a warning (see below).

### Test

Give a spec its own configuration so it does not touch the global one:

```crystal
require "spec"
require "azu"

describe "a test environment" do
  it "scopes a configuration to the block" do
    config = Azu::Configuration.new
    config.env = Azu::Environment::Test
    config.cache_config.store = "null"

    Azu.with_config(config) do
      Azu.current_config.env.test?.should be_true
      Azu.cache.set("key", "value").should be_false
    end

    Azu.current_config.env.test?.should be_false
  end
end
```

To serve requests against an app of your own, build it with `Azu::App.new(config)` and
`app.server(handlers)`; see [Test endpoints](../../how-to/testing/test-endpoints.md).

### Staging and production

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.template_hot_reload = false
    config.shutdown_timeout = 20.seconds
    config.cache_config.store = "redis"
    config.cache_config.redis_url = ENV["CACHE_REDIS_URL"]
  end
end
```

Set `CRYSTAL_ENV=production` in the process environment, `SPARK_SECRET` if you use Spark, and `SSL_CERT` / `SSL_KEY`
if Azu terminates TLS itself (a TLS-terminating proxy instead needs `SecurityHeaders.new(hsts: true)` in your own
handler array).

{% hint style="warning" %}
Behind a proxy, `Throttle` sees the proxy's address for every request unless the proxy is listed in its
`trusted_proxies:` ([Behind a reverse proxy](../handlers/built-in.md#behind-a-reverse-proxy)).
{% endhint %}

### Environment files

Keep one set of variables per environment and load it with your process manager. For example with Docker:

{% code title="production.env" %}
```bash
# production.env (never commit)
CRYSTAL_ENV=production
PORT=8080
HOST=0.0.0.0
# paste a generated value after the = (left empty, Azu::Spark.install stops the boot in production)
SPARK_SECRET=
CACHE_STORE=redis
CACHE_REDIS_URL=redis://redis:6379/0
DATABASE_URL=postgres://user:pass@host/db
```
{% endcode %}

```bash
docker run --env-file production.env myapp
```

Generate the secret once per deployment, with `openssl rand -hex 32` or
`crystal eval 'require "random/secure"; puts Random::Secure.hex(32)'`, and never reuse a value from an example.

### Per-app environments

Two apps in one process can run in different environments, because each has its own configuration:

```crystal
require "azu"

public_site = Azu::App.new
public_site.config.env = Azu::Environment::Production

admin = Azu::App.new
admin.config.env = Azu::Environment::Development

public_site.routes do
  mount admin, at: "/admin"
end
```

## See also

- [Configuration options](options.md)
- [Azu::Env](env.md)
- [Spark configuration](spark.md)
- [The Azu module](../api/app.md#the-azu-module)
