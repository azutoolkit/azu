# Add logging

Log requests and your own events in an Azu application. Azu logs through Crystal's standard `Log`; there is nothing
to learn beyond configuring `Log` and, if you want, writing a handler.

## Built-in Logger

`Azu::Handler::Logger` writes one line per request, after the rest of the chain has run. It is part of the default
stack, so an app started with `MyApp.start` already has it. To choose the handlers yourself:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

A request produces a line like this (colors only on a terminal):

```text
127.0.0.1 ⤑ GET Path: /ok Endpoint: OkEndpoint Status: 200 Latency: 90.49µs
```

The line is logged at `Info` to the `Azu` source (`Azu::CONFIG.log`). Give the handler another `Log` to change the
source, for example to route request lines to their own file:

```crystal
Azu::Handler::Logger.new(Log.for("my_app.http"))
```

Put `Logger` outside `Rescuer` (as above) so a request that raised is logged with the `500` the client received.

## Set Up Log Output

Requiring `azu` does not touch `Log`, so by default Crystal's own defaults apply (`Info` and above to standard
output). Two ways to take control, both once at boot before `start`:

Azu's format at `Debug`:

```crystal
require "azu"

Azu.setup_logging
```

or your own backend and level per source:

```crystal
require "azu"

Log.setup do |config|
  backend = Log::IOBackend.new(STDOUT)
  config.bind "*", Azu::CONFIG.env.production? ? Log::Severity::Info : Log::Severity::Debug, backend
end
```

Azu's own messages come from the sources `Azu` (request lines), `Azu::Rescuer` (errors answered by `Rescuer`),
`Azu::Router` (unrouted paths) and `Azu::Cache::MemoryStore` / `Azu::Cache::RedisStore`, so you can bind those names to
different levels or backends.

## Logging in Endpoints

Log with your own `Log` source inside endpoints:

```crystal
module Accounts
  Log = ::Log.for("accounts")
end

struct SignupRequest
  include Azu::Request

  getter email : String

  def initialize(@email = "")
  end

  validate email, presence: true
end

struct SignupResponse
  include Azu::Response

  def initialize(@email : String)
  end

  def render
    {email: @email}.to_json
  end
end

struct SignupEndpoint
  include Azu::Endpoint(SignupRequest, SignupResponse)

  post "/signup"

  def call : SignupResponse
    Accounts::Log.debug { "Signing up #{signup_request.email}" }
    Accounts::Log.info { "Signed up #{signup_request.email}" }
    SignupResponse.new(signup_request.email)
  rescue ex
    Accounts::Log.error(exception: ex) { "Signup failed" }
    raise ex
  end
end
```

The block is only evaluated when the severity is enabled for that source.

## Log Backends

### File

```crystal
require "azu"

Dir.mkdir_p("log")
file = Log::IOBackend.new(File.new("log/app.log", "a"))

Log.setup do |config|
  config.bind "*", Log::Severity::Info, file
end
```

Azu does not rotate log files. Rotate them outside the process (with logrotate, `copytruncate` avoids having to
reopen the file).

### JSON

A backend turns a `Log::Entry` into whatever your log pipeline reads. This one writes one JSON object per line:

```crystal
require "azu"
require "json"

class JsonLogBackend < Log::Backend
  def initialize(@io : IO = STDOUT)
    super(Log::DispatchMode::Sync)
  end

  def write(entry : Log::Entry) : Nil
    data = {
      "timestamp" => entry.timestamp.to_rfc3339,
      "severity"  => entry.severity.to_s,
      "source"    => entry.source,
      "message"   => entry.message,
    }
    data["exception"] = entry.exception.try(&.message) || "" if entry.exception
    entry.context.each { |key, value| data[key.to_s] = value.to_s }
    entry.data.each { |key, value| data[key.to_s] = value.to_s }
    @io.puts data.to_json
  end
end

Log.setup do |config|
  config.bind "*", Log::Severity::Info, JsonLogBackend.new
end
```

### Several Backends

```crystal
require "azu"

Log.setup do |config|
  stdout = Log::IOBackend.new(STDOUT)
  file = Log::IOBackend.new(File.new("app.log", "a"))

  config.bind "*", Log::Severity::Info, file
  config.bind "*", Log::Severity::Error, stdout
end
```

## Request Context in Every Log Line

`Azu::Handler::RequestId` registers the request being served for the current fiber. Anywhere below it,
`Azu::RequestContext.current?` returns its id, method and path, so a log call deep inside your code can say
which request it belongs to:

```crystal
module Billing
  Log = ::Log.for("billing")

  def self.charge(cents : Int32) : Nil
    request_id = Azu::RequestContext.current?.try(&.request_id) || "-"
    Log.info { "[#{request_id}] charging #{cents} cents" }
  end
end
```

For metadata that Crystal's `Log` attaches to every entry of a fiber, set it from a handler:

```crystal
class LogContextHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    ::Log.with_context(request_id: context.request.headers["X-Request-ID"]?) do
      call_next(context)
    end
  end
end
```

Place it after `RequestId`. A backend such as the JSON one above then sees `request_id` in `entry.context`.

## A Structured Request Logger

If `Logger`'s line is not what you want, replace it with a handler. This one logs a single JSON line with the
fields most dashboards need:

```crystal
class StructuredLogger
  include HTTP::Handler

  Log = ::Log.for("http.access")

  def call(context : HTTP::Server::Context)
    start = Time.instant
    begin
      call_next(context)
    ensure
      log_request(context, Time.instant - start)
    end
  end

  private def log_request(context : HTTP::Server::Context, elapsed : Time::Span) : Nil
    Log.info { {
      request_id:  context.request.headers["X-Request-ID"]?,
      method:      context.request.method,
      path:        context.request.path,
      status:      context.response.status_code,
      duration_ms: elapsed.total_milliseconds.round(2),
      remote:      context.request.remote_address.try(&.to_s),
      user_agent:  context.request.headers["User-Agent"]?,
    }.to_json }
  end
end
```

Use it instead of `Azu::Handler::Logger`, outside `Rescuer`, so the status is the final one.

## Logging Slow Requests Only

```crystal
class SlowRequestLogger
  include HTTP::Handler

  Log = ::Log.for("http.slow")

  def initialize(@threshold : Time::Span = 1.second)
  end

  def call(context : HTTP::Server::Context)
    start = Time.instant
    begin
      call_next(context)
    ensure
      elapsed = Time.instant - start
      if elapsed > @threshold
        Log.warn { "#{context.request.method} #{context.request.path} took #{elapsed.total_seconds.round(2)}s" }
      end
    end
  end
end
```

## What Not to Log

`Azu::Handler::Logger` logs the request target with its query string, and never headers or bodies. It passes the
target through `Azu::Env.redact_url` first, which replaces the value of a credential-looking query parameter and the
password of a URL: `/data?token=abc123&page=2&api_key=zzz` is logged as
`/data?token=[FILTERED]&page=2&api_key=[FILTERED]`. Keep your own handlers as careful: `Authorization`, cookies and
form bodies carry credentials. If you must log a request-derived hash, filter it with `Azu::Env.redacted`, which
replaces the values of keys that look like secrets (`password`, `token`, `api_key`, `authorization`, ...) with
`[FILTERED]` and redacts URLs in the other values:

```crystal
Azu::Env.redacted({"name" => "Ada", "password" => "hunter2", "next" => "https://u:p@example.com/x?token=1"})
# => {"name" => "Ada", "password" => "[FILTERED]", "next" => "https://u:[FILTERED]@example.com/x?token=[FILTERED]"}
```

## See Also

- [Create Custom Middleware](create-custom-middleware.md)
- [Built-in handlers](../../reference/handlers/built-in.md)
