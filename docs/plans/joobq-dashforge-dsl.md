# Unified JoobQ and Dashforge DSL

Status: proposal, nothing implemented or pushed. Evidence: shallow clones of `azutoolkit/joobq` (v0.4.2, HEAD 6ea07e1, 2026-01-31) and `azutoolkit/dashforge` (v0.2.0, last commit 2022-05-30), Crystal 1.22.0 via Docker, and a macro spike (scratchpad `dsl/t.cr`, results quoted in section 3).

## 1. Audit

### 1.1 JoobQ (src/joobq, ~8k LOC)

| Area | What exists (file:line) |
|---|---|
| Job contract | `module JoobQ::Job` with `macro included` (`job.cr:106`): includes `JSON::Serializable` and `JSON::Schema`; ivars `jid`, `queue`, `retries`, `max_retries`, `expires`, `status`, `error`; `Status` enum (Completed, Dead, Enqueued, Expired, Retrying, Running, Scheduled); `abstract def perform`. It is a **module you `include`, not a class you inherit** (`< JoobQ::Job` does not compile). |
| Class-level API (`job.cr:182-245`) | `batch_enqueue`, `enqueue(**args)`, `perform` / `perform(**args)` (runs inline), `enqueue_at(Time::Span, **args)`, `delay(for:, **args)`, `schedule(every:, **args)`. No `perform_async`, `perform_at`, `retry_policy`, `rate_limit`, `param`. |
| Per-job options | Plain ivar defaults: `@queue = "x"`, `@retries = 3`, `@expires = ...` (README:284-300, dashforge `jobs/*.cr`). No `queue :sym` / `retries n, backoff:` macros. |
| Serialization | JSON only (`JSON::Serializable`). No BSON or MsgPack anywhere (grep empty). |
| Config | `Configure` (`configure.cr:21`): `store`, `default_queue`, `retries`(3), `expires`(3d), `timeout`(2s, see below), `failed_ttl`, `dead_letter_ttl`, `worker_batch_size`, pipeline_*, `middlewares`, `schedulers`, `delayed_job_scheduler`, `expired_job_reaper`, `error_monitor`. Macros: `queue(name, workers, job, throttle=nil)` with compile-time worker bounds `raise` (`configure.cr:188-199`), `register_job` (`:387`). YAML/CLI/env loading (`yaml_config_loader.cr`, `config_validator.cr`, `queue_factory.cr`). |
| Middleware | `Middleware` module (`matches?`, `call(job, queue, worker_id, next)`) plus `MiddlewarePipeline` (`middleware.cr`). Defaults (`configure.cr:137-141`): `Throttle`, `Retry`, `Timeout`. |
| Retry | `Middleware::Retry` + `ExponentialBackoff` (`middlewares/retry.cr`): delay is hard-coded `2**attempt` seconds capped at 1h, Redis `SET NX` lock for idempotency. Not configurable per job; dead-letter after retries exhausted (`DeadLetterManager`, `dead_letter_manager.cr:15`). |
| Rate limit | `Middleware::Throttle` is **per queue** (`queue ..., throttle: {limit:, period:}`), implemented as a mutex plus `sleep` (min interval). Not per job class, not distributed. |
| Timeout | `Middleware::Timeout` only checks `job.past_expiration?` before running; it does **not** bound execution time. `Configure#timeout` is not enforced anywhere I found. |
| Execution | `Worker(T)#handle_job_async` (`worker.cr:~105`): parse, `running!`, run pipeline, `perform`, `completed!`, cleanup. Fibers per job. No event/hook emission. |
| Scheduling | `Scheduler` (cron + every + delay), `DelayedJobScheduler`, `RecurringJobScheduler`, `CronJobScheduler`. |
| Telemetry today | `ErrorMonitor` + `ErrorContext` + `MonitoredErrorHandler` (errors only, alert thresholds, callback), `RedisMetrics`/`collect_statistics_batch`, Log lines, REST `APIServer` (`/joobq/health/check`, `/errors/stats`, `/jobs/dead`, `/pipeline/stats`...). No success/latency event stream, no subscriber interface. |
| Workflows | **None.** `grep -i "workflow\|compensat\|saga"` over src: zero hits (only comment "Step 1" text). |
| Testing support | None for users. No `JoobQ::SpecHelper`. Internal helper jobs live in `spec/helpers/all_test_jobs_spec.cr`. |

README vs reality: README documents `include JoobQ::Job`, ivar options, `enqueue`, `delay`, `schedule`, queue throttle, REST API, YAML config. Mismatches: README:323 `enqueue_at(time: 3.minutes.from_now, ...)` but the signature takes a `Time::Span` (`job.cr:219`); README:296 `@expires = 1.days.total_seconds.to_i` but `expires` is `Int64` unix-ms; README claims retry "exponential backoff" without saying it is not tunable. CLAUDE.md in the repo says version 0.4.1 vs shard 0.4.2.

### 1.2 Dashforge (src/dashforge)

It is an **application, not a library**: `src/dashforge.cr` requires `azu`, configures it, and calls `DashForge.start [...]` at require time (module name `DashForge`, not `Dashforge`). Contents: 8 Azu components (counters, tables, chart), 5 endpoints (`/`, `/queues/:queue`, `/queues/traces/:name`, `/queues/:queue/jobs/:job_id`, `/scheduled`), `ChartsChannel` (`/charts-data` WS), demo jobs, `config/joobq.cr` that reads `ENV[...].not_nil!` for worker counts. Pins `azu 0.1.11`, lock has `joobq 0.3.1`.

Not present: `Dashforge::Engine`, `mount`, `auth:`, `track_gauge`/counter/histogram, tags, any metrics API of its own. Metrics are read from `JoobQ::Statistics` (a Redis time-series class that exists in joobq 0.3.1, `lib/joobq/src/joobq/statistics.cr`, but **was removed in joobq 0.4.x**), so Dashforge cannot work against current joobq without porting to `RedisMetrics`. README (163 lines) only covers Fly.io/Docker deployment. Spec: one placeholder (`false.should eq(false)`).

### 1.3 Azu mounting (read from /home/user/azu/src/azu)

- `Azu::CONFIG = Configuration.new` is a global (`azu.cr:18`); `Configuration#router` is one `Router.new` (`configuration.cr:64`). `Azu.current_config` can return a fiber-local config (`azu.cr:~44`), but endpoint macros ignore it.
- `Endpoint(Req, Res)` (`handler/endpoint.cr:24`) is an `Azu::Routable` (not an `HTTP::Handler`); `macro included` defines `self.get/post/...(path)` which store `@@resource` and call `Azu::CONFIG.router.<verb> path, self.new` (`endpoint.cr:70-75`). Registration is therefore a side effect of class body execution, always on the global router, always at the literal path given. There is no prefix.
- `Router` (`router.cr:38`) is a plain class, **not** an `HTTP::Handler`. Public: `get/post/...(path, handler)` (generated from `RESOURCES`), `add(path, endpoint, method)` (stores radix key `"/#{method}#{path}"`), `root`, `ws(path, Channel.class)`, `routes(scope = "", &)`, `process(context)`, `route_info`, `clear_path_cache`. Duplicate routes raise `Router::DuplicateRoute`.
- `Router#routes(scope, &)` yields a `Builder` whose `@scope` is **stored but never used** (`router.cr:125-146`, Builder only `forward_missing_to @router`), so scoped routes are not actually prefixed today.
- `Azu.start(handlers)` builds `HTTP::Server.new(handlers) { |ctx| config.router.process(ctx) }` (`azu.cr:102-106`). There is no `mount`, no sub-app/engine concept, no path-prefix stripping.
- Conclusion: `mount Dashforge::Engine, at: "/dashforge"` does not exist; implementing it needs either (a) a small Azu change (section 3.4) or (b) a Dashforge-local `HTTP::Handler` that sits in the handler list and prefix-dispatches before the router, which needs no Azu change.

### 1.4 Spec baseline (Crystal 1.22.0, Docker)

| Repo | Result |
|---|---|
| joobq, as cloned (`crystal spec`) | **Does not compile.** `spec/spec_helper.cr:6` requires `./helpers/all_test_jobs` but the file is named `spec/helpers/all_test_jobs_spec.cr`; `crystal spec` also loads that file standalone (`undefined constant JoobQ::Job`). |
| joobq, in a scratch copy with the helper renamed to `all_test_jobs.cr` and local Redis 7 | `264 examples, 1 failures, 0 errors, 3 pending`. Failure: `ExpiredJobReaper scan_limit respects the scan limit` (`expired_job_reaper_spec.cr:174`, expected queue size 100, got 0). Pending: concurrent enqueue, delayed-scheduler auto-process, `Queue#start`. |
| dashforge (`shards install` then `crystal spec`) | **Does not compile**: `lib/crinja/src/runtime/resolver.cr:58` `no overload matches Proc(Crinja::Arguments, Crinja::Value)#[]` (old crinja 0.8.0 via azu 0.1.11 on Crystal 1.22). Only one placeholder spec exists regardless. |

Coverage notes (joobq, `it` counts): job_spec 66, retry_refactor 28, api_validation 31, yaml_config 23, queue_factory 17, worker_manager 16, middleware 13, others small. Not covered: macro DSL (none exists), throttle timing, timeout, real worker end-to-end, telemetry.

## 2. Before / after

Legend: PRESENT = works today; PARTIAL = building blocks exist; MISSING.

| Feature | Today | Target | Status |
|---|---|---|---|
| Job definition | `struct X; include JoobQ::Job; @queue="q"; def initialize(@a : String); def perform` | `class X < JoobQ::Job` | MISSING (module, not class) |
| Queue | `@queue = "critical"` | `queue :critical` | PARTIAL (ivar default) |
| Params | hand-written `initialize` + `property` | `param email : String` | MISSING |
| Enqueue | `X.enqueue(email: "a")` (named args, `**args` untyped until `new`) | `X.perform_async("a", 42_i64, delay: 10.minutes)` | PARTIAL (`enqueue`, `enqueue_at(Span)`, `delay(for:)`) |
| Enqueue at time | none for absolute `Time` | `X.perform_at(time, ...)` | MISSING |
| Retries | `@retries = 5` | `retries 5, backoff: :exponential` | PARTIAL (count yes; backoff fixed 2^n s, cap 1h) |
| Retry policy | none | `retry_policy :aggressive` / `JoobQ.retry_policy` | MISSING |
| Rate limit | `queue "q", 5, X, throttle: {limit: 100, period: 1.minute}` (per queue) | `rate_limit max: 100, per: 1.minute` (per job class) | PARTIAL |
| Exec timeout | none (only expiry check) | `timeout 30.seconds` | MISSING |
| Dead letter | automatic after retries | default on, configurable TTL | PRESENT |
| Workflow | none | `class OrderFlow < JoobQ::Workflow; workflow_name; timeout; def execute; step ... ; compensate` | MISSING |
| Metrics | Dashforge reads removed `JoobQ::Statistics` | `Dashforge.track_gauge "inventory.stock_level", value: 42, tags: {...}` | MISSING |
| Mount | Dashforge is its own server | `mount Dashforge::Engine, at: "/dashforge", auth: :admin` | MISSING (Azu has no mount) |
| Telemetry from jobs | logs + error monitor only | automatic job/workflow events to Dashforge, compile-time opt-in | MISSING |
| Compile-time errors | `queue` macro worker bounds only (`configure.cr:188`) | all DSL macros validate | PARTIAL |
| Test helper | none | `JoobQ::SpecHelper` | MISSING |
| Serialization adapters | JSON only | JSON/BSON/MsgPack | MISSING |

## 3. Design

### 3.1 Job DSL (spike-verified)

Make `JoobQ::Job` an `abstract class` (inherits nothing) that keeps today's public instance API. Keep `module JoobQ::Job` working via a deprecated shim (3.6). Macros are defined once in `macro inherited` with `{% verbatim do %}` so they are scoped per subclass.

Verified on Crystal 1.22.0 in the spike:
- `class SendWelcomeEmail < Job` with `queue :critical` and `param email : String` / `param user_id : Int64` compiles and `SendWelcomeEmail.perform_async("a@b", 42_i64, delay: 10.minutes)` is **typed from the params**; passing `"42"` gives `expected argument #2 to 'SendWelcomeEmail.perform_async' to be Int64, not String` listing the overload `perform_async(email : String, user_id : Int64, delay : Time::Span | ::Nil = nil)`.
- `{% raise %}` in a macro surfaces as e.g. `Error: X: unknown backoff :expo; expected :exponential, :linear or :fixed`.
- Gotcha: `TypeNode#instance_vars` is **not usable** from `macro finished` ("instance vars are not yet initialized"), and `{% CONST = ... %}` accumulators cannot be created inside a nested macro. Working technique: each `param` also emits an annotated marker method `@[Param] def __param_email : String`, and a top-level `macro finished` iterates `Job.all_subclasses` and `t.methods.select { |m| m.annotation(Param) }` (names from the marker, types from `return_type`) to generate `initialize` and `perform_async`. Phase 1 must keep this as its first spike test.

Sketch of the expansion:

```crystal
abstract class JoobQ::Job
  include JSON::Serializable            # default adapter, see 3.5
  macro inherited
    {% verbatim do %}
    macro queue(name)        # validates SymbolLiteral|StringLiteral
      def self.queue_name : String; {{name.id.stringify}}; end
    end
    macro retries(n, backoff = :exponential, base = 1.second, max = 1.hour)
      # validates Number >= 0, backoff in [:exponential,:linear,:fixed]
      def self.retry_policy : JoobQ::RetryPolicy
        JoobQ::RetryPolicy.new({{n}}, :{{backoff.id}}, {{base}}, {{max}})
      end
    end
    macro rate_limit(max, per) ... def self.rate_limit : JoobQ::RateLimit? ... end
    macro timeout(span) ... end
    macro param(decl)        # property + @[Param] marker method
      property {{decl.var}} : {{decl.type}}
      @[Param] def __param_{{decl.var}} : {{decl.type}}; @{{decl.var}}; end
    end
    {% end %}
  end
end
# generated per subclass (top-level macro finished):
#   def initialize(@email : String, @user_id : Int64)
#   def self.perform_async(email : String, user_id : Int64, *, delay : Time::Span? = nil, at : Time? = nil)
#   def self.perform_at(time : Time, email : String, user_id : Int64)
#   def self.perform_now(...)   # inline, replaces today's class-level `perform(**args)`
```

Defaults come from `JoobQ.config` as today (retries 3, queue "default", dead-letter on). Class-level `queue_name`, `retry_policy`, `rate_limit`, `timeout` are `def self.` with defaults in the base class, so the Retry/Throttle/Timeout middleware read them from `job.class` with no ivar copying. Naming standard: `perform_async`, `perform_at`, `perform_now`, `queue`, `retry_policy`, `step`, `compensate`; old `enqueue`, `enqueue_at`, `delay`, `schedule`, `batch_enqueue` stay as deprecated aliases for one minor.

Fixes needed regardless: make `Retry` use `RetryPolicy#delay(attempt)` (default identical to today's 2^n s, 1h cap); a real `Timeout` (`select` on a `Channel` plus `timeout`, raising `JoobQ::JobTimeout`, retried as a normal failure); per-class `RateLimit` replacing the sleeping mutex (keep queue throttle as fallback; consider a Redis token bucket for multi-process correctness).

### 3.2 Workflow (Temporal-inspired, minimal)

```crystal
class ProcessOrder < JoobQ::Workflow
  workflow_name "process_order"
  timeout 30.minutes

  def execute(order_id : String)
    step :charge_card, timeout: 10.seconds do
      Payments.charge(order_id)
    end
    step :reserve_stock { Inventory.reserve(order_id) }
    step :ship { Shipping.create(order_id) }
  rescue ex
    compensate          # runs registered compensations of completed steps, reverse order
    raise ex
  end

  compensate :charge_card { Payments.refund(order_id) }   # pairs with the step by name
end
ProcessOrder.start("o-123")     # => workflow id
```

Design: a `Workflow` is a `Job` subclass (reuses queue, retry, serialization). `execute` args become `param`s via the same `finished` macro (`start` typed like `perform_async`). `step` is a macro expanding to `run_step(:name, timeout) { }` which (1) checks the persisted step log (`Store`: `workflow:<id>:steps` hash of name to status/result) and **skips completed steps on replay**, (2) records `started/completed/failed`, (3) emits telemetry. `compensate :name { }` registers a block in a class-level table (compile-time name check against declared `step` names; error if no matching step). Bare `compensate` inside `rescue` walks completed steps in reverse and runs their blocks, recording `compensated`. Scope limits (explicitly not Temporal): at-least-once steps (must be idempotent), no deterministic replay of arbitrary code, no signals/child workflows/timers in v1.

New small interfaces: `Workflow::StepLog` (`record`, `completed?`, `list`) with a Redis implementation on the existing `Store`, plus in-memory implementation for specs.

### 3.3 Telemetry hook (compile-time opt-in)

```crystal
module JoobQ::Telemetry
  abstract class Observer
    def job_enqueued(e : JobEvent) : Nil; end     # no-op defaults: a subscriber overrides only what it needs
    def job_started(e : JobEvent) : Nil; end
    def job_succeeded(e : JobEvent, elapsed : Time::Span) : Nil; end
    def job_failed(e : JobEvent, ex : Exception, will_retry : Bool) : Nil; end
    def job_dead(e : JobEvent) : Nil; end
    def step_finished(e : StepEvent, status : Symbol, elapsed : Time::Span) : Nil; end
  end
  class Null < Observer; end
  class Multi < Observer ... end                   # fan-out to several
  class_property observer : Observer = Null.new

  macro emit(call)
    {% if flag?(:joobq_telemetry) %} ::JoobQ::Telemetry.observer.{{call}} {% end %}
  end
end
```

`JobEvent` is a `struct` (jid, class name, queue, attempt, tags). Worker/Retry/Workflow call `Telemetry.emit job_started(ev)`. Without `-Djoobq_telemetry` the macro expands to nothing (spike confirmed the flag builds both ways), so unused instrumentation costs zero code and zero allocations (events are constructed inside the macro expansion only). Dashforge ships `Dashforge::JoobQObserver < JoobQ::Telemetry::Observer`; `require "dashforge/joobq"` sets the flag requirement (docs: build with `-Djoobq_telemetry`; the require raises a compile error via `{% skip_file unless flag?(:joobq_telemetry) %}`-style message if missing). JoobQ does not depend on Dashforge (dependency inversion); Dashforge depends on JoobQ's Observer interface only.

Dashforge side: `Dashforge.track_gauge/track_counter/track_histogram(name, value:, tags: NamedTuple|Hash)` forwards to a `Dashforge::Sink` (interface `write(Metric)`; default `RedisSink` reusing JoobQ's Redis pool, `MemorySink` for specs). `tags` typed as `Hash(String, String)` with a `NamedTuple` overload. Metric names validated (`/\A[a-z0-9_.]+\z/`) at compile time when the name is a literal.

### 3.4 Mounting in Azu

Smallest viable path, in order of preference:
1. **No Azu change**: `Dashforge::Engine < HTTP::Handler` owns its own router, strips `at:` prefix, handles auth, and delegates other requests via `call_next`. User adds it to the `Azu.start [...]` handler list. `mount Dashforge::Engine, at: "/dashforge", auth: :admin` becomes a top-level macro in Dashforge that appends to a registry the user splices: `Azu.start [Dashforge.handler, ...]`. This is honest about Azu's current limits.
2. **Small Azu PR** (separate repo, optional): make `Router` honour `Builder#@scope` (currently dead code) and add `Router#mount(handler : HTTP::Handler, at : String)`: add radix routes `"/{verb}{at}/*path"` for each verb pointing at a `PrefixStrip` handler. Endpoints inside the engine must register on an engine-owned `Router`, so `Endpoint.included` needs an overridable `router` class method (default `Azu::CONFIG.router`); today it is hard-wired to the global.

`auth: :admin` resolves to a user-registered `Dashforge.auth(:admin) { |ctx| ... }` (a `Proc(HTTP::Server::Context, Bool)`); compile error if the symbol is not registered. Dashforge default for unauthenticated deployment in production: refuse to boot (open decision 4).

### 3.5 Serialization adapters

Introduce `JoobQ::Codec` (`encode(job) : Bytes|String`, `decode(T, data)`), default `JSONCodec` (today's behaviour, no new dependency). BSON and MsgPack are **opt-in shards** in separate files (`joobq/codec/bson`, `joobq/codec/msgpack`) selected by `JoobQ.configure { |c| c.codec = JoobQ::Codec::MsgPack }` and compile-time checked: `param` types must be serializable by the chosen codec (e.g. error: `ProcessOrder param 'meta : Hash(String, Foo)': type Foo does not include MessagePack::Serializable required by codec MsgPack`). Needs the Store to carry opaque strings/bytes (Redis supports it); `JSON::Schema` registry stays JSON-only.

### 3.6 Compile-time errors (where and what)

All validation in the macros of `src/joobq/dsl/*.cr`, one `JoobQ::DSL.fail(@type, macro, msg)` helper so every message has the form `JoobQ DSL error in <Class>: <macro> ...`:
- `queue 5` -> `` `queue` expects a Symbol or String literal, got 5 (NumberLiteral). Example: queue :critical ``
- `retries -1` / `retries 5, backoff: :expo` -> `` `retries` expects a non-negative Integer literal ``; `` unknown backoff :expo; expected :exponential, :linear or :fixed ``
- `rate_limit max: 0, per: 1.minute` -> `` `rate_limit max:` must be > 0 ``
- `param email` -> `` `param` expects `param name : Type`, e.g. param email : String ``
- duplicate `param` or `perform` missing -> `` SendWelcomeEmail must define `def perform` (JoobQ::Job#perform is abstract) ``
- `compensate :nope` -> `` compensate :nope has no matching `step :nope` in ProcessOrder (steps: charge_card, reserve_stock) ``
- wrong payload types at call sites are reported by the generated typed signature (shown above), and `perform_async` with an unserializable param type fails at the `param` line via the codec check.
Spec these with a compile-fail harness (`crystal build --no-codegen` on fixtures, assert stderr substring), since Crystal's `spec` cannot assert on `{% raise %}`.

### 3.7 `JoobQ::SpecHelper`

```crystal
require "joobq/spec_helper"
describe SendWelcomeEmail do
  include JoobQ::SpecHelper
  it "runs inline" do
    perform_now SendWelcomeEmail, "a@b", 42_i64         # runs #perform, no Redis, no queue
  end
  it "enqueues" do
    with_fake_queue do |q|                              # swaps Store for MemoryStore for the block
      SendWelcomeEmail.perform_async("a@b", 42_i64, delay: 10.minutes)
      q.enqueued(SendWelcomeEmail).size.should eq 1
      q.last.delay.should eq 10.minutes
      drain(q)                                          # runs jobs inline through the real middleware
    end
  end
  it "retries" { expect_retry(SendWelcomeEmail, "a@b", 1_i64) { raise "x" } }  # asserts policy, no sleeping
  it "workflow" { run_workflow(ProcessOrder, "o-1").steps.should eq [:charge_card, ...] }
end
```
Implementation: `MemoryStore < Store` (the `Store` abstract class already exists, `store.cr`), a `FakeClock` for delays, `RecordingObserver < Telemetry::Observer` to assert emitted events. Requires nothing but stdlib.

## 4. Phased plan (PR-sized)

| # | PR | Tests | Risks | Breaking |
|---|---|---|---|---|
| 0 | **Fix baselines**: rename `spec/helpers/all_test_jobs_spec.cr` -> `all_test_jobs.cr`; fix/pending the `ExpiredJobReaper` scan_limit spec; CI keeps Redis service. Dashforge: decide fate (open decision 1). | joobq green | trivial | none |
| 1 | **Job DSL core** (`dsl/job.cr`): abstract class `JoobQ::Job`, `queue/retries/param`, typed `perform_async/at/now`, compile-error helper, include-shim for module style, deprecated aliases. Start with the `finished`/marker-method spike test. | compile-fail fixtures; existing 264 specs unchanged via shim; Serialization round-trip | Crystal macro edge cases (generics, inheritance depth, `struct` jobs); `Queue(T)` and `QueueFactory.add_to_registry` rely on `include` hook | `struct X; include JoobQ::Job` keeps working; `< JoobQ::Job` is additive. Deprecate `enqueue*`. |
| 2 | **RetryPolicy + real Timeout + per-job RateLimit**; `Retry` middleware consumes `RetryPolicy`; DLQ stays default. | unit specs with FakeClock; timing-insensitive; Redis rate-limit integration | Changes retry timing semantics if defaults differ (keep 2^n s, cap 1h); Throttle redesign across processes | none by default; `Configure#timeout` becomes enforced only if set per job |
| 3 | **Telemetry observer** (`Observer`, `Null`, `Multi`, `emit` macro, hooks in Worker/Retry/DeadLetter). | `RecordingObserver` specs under `-Djoobq_telemetry`; second CI job compiles without flag and asserts a binary-size/allocation smoke test (`GC.stats` delta equals baseline) | Hook placement in async fiber paths; double-emit on retry | none |
| 4 | **SpecHelper + MemoryStore**. | dogfood: port a handful of joobq specs to use it | MemoryStore behaviour drift from RedisStore (run shared `Store` contract spec against both) | none |
| 5 | **Workflow** (`Workflow`, `step`, `compensate`, `StepLog`, redis + memory). | step skip-on-replay, compensation order, timeout, crash mid-step (kill fiber then resume), compile-fail for `compensate` names | Hardest design risk: at-least-once semantics, partial failure inside compensation (record and continue, surface in telemetry) | none (new) |
| 6 | **Codecs** (JSON default, MsgPack, BSON opt-in). | round-trip per codec with `param` type matrix | Store currently assumes JSON strings in indexing (`jid` extraction, API server, `JSON::Schema`); mixed codecs in one queue during rollout | none by default |
| 7 | **Dashforge restructure**: extract `Dashforge::Engine` (library) from the app; port off removed `JoobQ::Statistics` to `RedisMetrics`/Sink; add `track_gauge/counter/histogram`, `JoobQObserver`, `auth:`; upgrade Azu/crinja so it compiles on 1.22; real specs. | engine handler specs with `HTTP::Client`-free context helpers; sink contract spec; compile with Azu current | Largest effort: Dashforge is 4 years stale (azu 0.1.11, joobq 0.3.1); UI components rely on old Azu APIs | Package/module rename `DashForge` -> `Dashforge`; app entry moves to `bin/` |
| 8 | **Mount** (`Dashforge.handler` first; optional Azu PR for `Router#mount` + scoped Builder + engine-owned router). | Azu spec: prefixing, 404 outside prefix, auth reject | Azu release coupling; Builder scope currently dead code, fixing it changes `routes "/x"` behaviour for anyone relying on the no-op | Azu: `routes(scope)` starts honouring scope (document in changelog) |
| 9 | **Playground + docs**: `playground/orchestration_demo.cr` (job + workflow + Dashforge engine + gauge) and `playground/README.md`; README rewrite for new DSL; CLI templates (`azu_cli` joobq generators) follow in a separate PR. | demo compiled in CI (`crystal build --no-codegen`) | demo drift | none |

Cross-cutting test strategy: keep Redis-backed integration in CI, everything else on MemoryStore; compile-fail fixtures run via a spec that shells out to `crystal build --no-codegen`; run the matrix on the minimum supported Crystal and 1.22; benchmark `playground/bench.cr` before/after phases 1-3 to prove no regression (target: within 3%).

## 5. Open decisions for you

1. Dashforge fate: rewrite as library + app in the same repo (recommended), or build the new engine fresh and archive the old app?
2. `< JoobQ::Job` as a new abstract class with a compatibility shim for `include JoobQ::Job` (recommended), or a hard break at 0.5/1.0?
3. Add `Router#mount` (and fix dead `Builder#@scope`) in Azu, or ship the Azu-agnostic `Dashforge.handler` only for now?
4. Dashforge production default when `auth:` is omitted: refuse to boot (recommended) or open in development only?
5. Workflow semantics: at-least-once idempotent steps only (proposed), or invest in deterministic replay/signals later?
6. Telemetry opt-in flag name `-Djoobq_telemetry` and whether Dashforge's require should set it implicitly (impossible in Crystal; must be a build flag), plus tag cardinality limits.
7. Per-job `rate_limit`: process-local (cheap) or Redis token bucket (correct across workers; recommended)?
8. BSON/MsgPack: confirm both are needed in v1, or ship the Codec interface plus MsgPack first.
9. Deprecation window for `enqueue/enqueue_at/delay/schedule/batch_enqueue`: one minor or two?
10. Metric semantics for `track_gauge`: last-value only, or time series retention (Redis TS vs sorted sets) and default retention window?
