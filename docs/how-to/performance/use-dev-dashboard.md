---
description: Mount the development dashboard with the performance monitor that fills it, open it, and find what each tab shows.
---

# Use the dev dashboard

Before you start: an app that uses the `include Azu` facade and runs in development (`CRYSTAL_ENV` unset or
`development`).

{% stepper %}
{% step %}
#### Mount the dashboard and the monitor

The dashboard comes with `require "azu/dev"`. It shows the numbers of the shared performance monitor,
`config.performance_monitor`, so put that instance in the handler chain too:

{% code title="src/server.cr" %}
```crystal
require "azu"
require "azu/dev"

module MyApp
  include Azu
end

handlers = Azu::App.default.default_handlers
if monitor = MyApp.config.performance_monitor # nil unless PERFORMANCE_MONITORING=true
  handlers.unshift monitor
end
handlers.unshift Azu::Handler::DevDashboard.new if MyApp.env.development?

MyApp.start handlers
```
{% endcode %}

Both go in front of the default stack: the monitor then times the whole chain, and the dashboard answers its own
requests before the logger and the monitor see them, so its page and refreshes are not counted.
{% endstep %}

{% step %}
#### Start the app with monitoring on

```bash
PERFORMANCE_MONITORING=true crystal run src/server.cr
```

Without the variable there is no monitor: the dashboard still serves, but Overview, Logs and Performance Tracing
show no requests.
{% endstep %}

{% step %}
#### Open it

Send a few requests to your app, then open <http://127.0.0.1:4000/dev-dashboard>.
{% endstep %}
{% endstepper %}

![The development dashboard overview](../../assets/dev-dashboard/overview-light-desktop.png)

The page refreshes itself every 15 seconds, and skips a refresh while you are busy with it: a log entry or the
command palette open, focus inside a panel, text selected, or the browser tab hidden. **Live** pauses and resumes
the refresh. Press `/` to filter the current tab, `Ctrl K` (`Cmd K` on macOS) to search routes, logs and tabs, and
the trash button to clear the recorded numbers.

## What each tab shows

| Tab | Shows | Filled by |
| --- | --- | --- |
| Overview | What needs attention, uptime, memory, latency, routes, traffic, errors, cache, database, components and runtime | All of the below |
| Logs | Requests, cache operations and component events, newest first; each opens into a request and response inspector | The monitor; cache and component events while monitoring is on |
| Errors | Every server error since boot, grouped by class and the line that raised it; each opens its exception page ([Debug exceptions](../errors/debug-exceptions.md)) | `Rescuer`, in development, with or without the monitor |
| Routes | The handler pipeline given to `start` and every registered route | The app itself |
| Components | Mount, refresh and event timings of live components | Live components, while monitoring is on |
| Performance Tracing | Latency distribution, slowest requests, endpoints by average time, profiler spans, memory trend | The monitor, the profiler and the memory monitor |
| Database | Query KPIs, slow queries, patterns, N+1 analysis, transactions, connection pool, SQL playground | An ORM integration: `require "azu/cql"` ([Database dashboard](../../reference/database-dashboard.md)) |
| Cache | Hit rate, operation breakdown, recent operations | `Azu::Cache` operations, while monitoring is on |
| Config | Server, templates, cache, performance, assets, uploads and i18n settings | The app's configuration |

## Time your own code

In development the profiler is on from `start`. Wrap a block to see it under **Profiler spans** in Performance
Tracing:

```crystal
require "azu"
require "azu/dev"

report = Azu::DevelopmentTools.profile("build report") do
  (1..1000).sum
end
```

## Serve it at another path

```crystal
require "azu"
require "azu/dev"

dashboard = Azu::Handler::DevDashboard.new("/__dev") # the SQL playground moves to /__dev/sql
```

{% hint style="danger" %}
The dashboard has no login. It serves only in development, where Azu listens on `127.0.0.1` by default. If you bind
another address in development (`HOST=0.0.0.0`, as in a container), anyone who can reach the port sees your
requests, SQL and configuration.
{% endhint %}

## See also

- [Monitor performance in development](monitor-performance.md)
- [Dev tools](../../reference/dev/azu-dev.md)
- [Database dashboard](../../reference/database-dashboard.md)
- [Performance design](../../explanation/architecture/performance-design.md)
