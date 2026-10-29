# Request-path performance and concurrency

This review targets Azu v1.0.3 (`bfba09ee16ca1fb0157a9d1762c4448bdd44ccf2`),
Crystal 1.22.1 and the changes on `codex/azu-performance-review`. These are
local measurements, not a TechEmpower submission or a production latency SLA.

## Changes and allocation ownership

| Change | Reason | Compatibility and cost |
| --- | --- | --- |
| RequestContext stored on its owning Fiber | Removes a process-wide hash lookup and mutex from every context read, entry and exit | Nested scopes share the same Info; exceptions restore state; child fibers start empty. Info remains a class because instrumentation mutates shared metadata. |
| App/config scope stored as a value on Fiber | Removes the second global registry and its mutex from configuration reads and request dispatch | `with_scope`, `with_app`, `with_config` and explicit `spawn_scoped` propagation retain their behavior. A global atomic generation preserves `clear_fiber_configs`; invalidated references are released on the next config access or scope exit. |
| `Response::Json(T)` struct | Serializes a typed value straight to buffered HTTP IO, eliminating the complete intermediate JSON String | Opt-in. A small IO adapter leaves flush timing to HTTP. `render` still returns a String when explicitly requested. The adapter, JSON::Builder and HTTP parsing still allocate. |
| Bounded TemplateContext body reader | Stops an overlooked `gets_to_end` from buffering an arbitrary upload | Reads at most `upload.max_file_size + 1` bytes and raises a 413 error. |
| Explicit connection close on 413 | Crystal discards a connection with an unread body; advertising keep-alive caused the next client POST to fail | No unbounded body drain. Clients reconnect after the refusal; accepted uploads can reuse their connection. |

The fiber properties add fixed storage to each Fiber, including fibers unrelated to
HTTP. They replace registry storage; they do not remove the HTTP request, response,
headers, Info, or connection allocations. A struct is a value type, **not a guarantee
of stack allocation**: escaping values and interface boxing depend on compiler output.
Class endpoints continue to be duplicated for request isolation; their referenced
mutable fields are still shared by a shallow duplicate. Prefer stateless struct
endpoints and concurrency-safe services rather than assuming `dup` copies service state.

## Direct JSON response

```crystal
struct MessageRequest
  include Azu::Request
end

alias MessageResponse = Azu::Response::Json(NamedTuple(message: String))

struct MessageEndpoint
  include Azu::Endpoint(MessageRequest, MessageResponse)

  get "/message"

  def call : MessageResponse
    MessageResponse.new({message: "Hello, World!"})
  end
end
```

The response sets `application/json`. Named tuples avoid intermediate generic
hashes; `JSON::Serializable` models and custom `to_json(JSON::Builder)` methods
also work. Set status and custom headers before returning. Serialization writes
through `HTTP::Server::Response`, preserving HTTP framing, compression handlers
and Azu's HEAD suppression. Small responses fit the server's existing buffer;
larger responses can use chunked transfer encoding.

Calling ordinary `value.to_json(context.response)` is not equivalent: Crystal's
JSON builder flushes at `end_document`. That prematurely commits headers for small
responses and forces chunked framing. The response's IO adapter suppresses
that flush; the HTTP server still flushes and closes normally. A framing regression
test and the socket benchmark check Content-Length and the absence of chunking for
the small JSON response.

Large direct responses can commit headers before serialization completes. A
serializer failure then cannot be replaced with a clean 500 response; a client
can receive incomplete JSON. Partial buffered output can also affect error rendering
before headers are sent. Use a buffered response for fallible serialization
that requires all-or-nothing output. Do not put database calls or other fallible
external operations inside `to_json`; prepare and validate the value first.
This tradeoff is why existing `render` responses have not silently changed.

## Routing, middleware and parsing audit

The segment trie already matches static routes without GC allocations, regexes
or substring Strings. Parameter captures allocate owned Strings and a Hash so
application code can retain them safely. Bounds normally live in a fixed stack
array; exceptionally deep routes use a bounded heap slice. Static lookup cost
depends on path length/segment count, not a linear scan of all registered routes.
Ambiguous static/parameter branches can backtrack: the worst case is proportional
to visited trie nodes, **not a universal O(1) or O(log N) guarantee**. Preserve
static-before-parameter-before-glob precedence when changing this algorithm.

Middleware is a linked HTTP::Handler chain assembled at boot; no per-request
middleware array or closure is constructed. Dynamic dispatch and call depth remain
proportional to the number of configured handlers. Removing security, correlation
or shutdown tracking to improve a benchmark would measure a different stack.

Typed request decoding already uses generated deserializers and JSON::PullParser
for URL overrides. It buffers the bounded body to preserve the raw JSON/parameter
API. Changing that to destructive stream parsing would change observable behavior.
No global body-buffer pool was introduced: retained peak-size buffers, cross-request
data exposure and pool contention are significant costs. Prefer bounded inputs
and explicit streaming IO for large uploads.

## Multi-core configuration and remaining boundaries

On Crystal 1.22.1 the modern default execution context starts with one worker.
An application that opts into parallel request handling can resize it at boot:

```crystal
Fiber::ExecutionContext.default.resize(Fiber::ExecutionContext.default_workers_count)
```

`CRYSTAL_WORKERS=16` supplies the requested count. The deprecated `-Dpreview_mt`
build instead uses the legacy scheduler; do not invoke the execution-context API
in that build. The benchmark fixture handles both. CI exercises both schedulers
at 16 workers, including overlapping scopes, shutdown, routing and concurrent POSTs.
Sixteen workers are not sixteen available cores: tune against the CPU quota and
leave capacity for database clients and the load generator.

These tests establish invariants for the exercised paths, not universal thread
safety for every application and extension. Important boundaries remain:

- Configure routes, helper registries, CSRF defaults, i18n and global CONFIG before
  serving. Mutable configuration and user handlers are not generally safe for
  concurrent writes. Azu's per-app scopes isolate selection, not the configuration
  objects themselves.
- Request-ID entropy still has a mutex around its bounded secure-random buffer.
  It preserves unguessable IDs and amortizes system calls; removing that lock
  without a separate ownership design would be unsafe.
- Raw `request.body` remains IO an application can read without limits. Framework
  parser limits cannot bound user-created buffers or arbitrary middleware.
- Default per-body and connection limits are independent. Their product can exceed
  RAM by a large margin; size both from an explicit memory budget and enforce ingress
  limits. Typed parsing and model allocations add to the raw body budget.
- CPU-bound application work must yield or move to a suitable execution context.
  Cooperative scheduling cannot make an arbitrary busy loop fair. Database/Redis
  pool waits, TLS, logging, tracing and real payloads must be measured separately.

## Reproducing the measurements

Build baseline binaries from the base revision before applying source changes,
using the same `http_hot_path.cr` fixture (without `bench_direct_json`). Build the
candidate with the opt-in response enabled:

```sh
crystal build --release --no-debug benchmark/micro/hot_path.cr -o bin/hot-path
crystal build --release --no-debug -Dbench_direct_json benchmark/micro/http_hot_path.cr -o bin/http-after
crystal build --release --no-debug benchmark/micro/json_io.cr -o bin/json-io
bin/hot-path
bin/json-io
python3 benchmark/driver/hot_path.py bin/http-before bin/http-after /tmp/azu-http-results.json
```

The Python 3 runner needs `wrk` in PATH. It checks real response bytes and request
IDs, uses two load-generator threads and 64 keep-alive connections, alternates
before/after ordering, and records three 4-second samples after 1-second warmups
for 1, 4 and 16 server workers. It fails on non-success responses or socket errors.
Both builds retain default middleware except request logging, plus server limits
and shutdown tracking. JSON compares the old buffered value with the new opt-in
serializer; plaintext isolates the scope changes. The generator shares the server's
CPU budget. These short closed-loop samples do not characterize overload queues,
coordinated omission, TLS termination, long soaks or multi-host production traffic.

The in-process harness includes HTTP parsing and response framing but no socket;
its existing method reports the smallest of three windows. Repeat it and compare
medians across executions. `json_io.cr` measures creation, serialization and closing
of fresh HTTP responses backed by a reused null sink, including the deferred-flush
adapter. Input parsing and application logic are excluded; its allocation savings
must not be presented as whole-request savings.

## Results: 2026-10-29

Linux container on AMD EPYC 9V74, five visible CPUs, **four CPUs of cgroup quota**,
32 GiB memory limit. Crystal 1.22.1 release builds, wrk on the same host. No compiler
or test suite ran during timed samples. Before is the pristine base checkout;
after includes the final deferred-flush adapter. All 36 samples completed without
reported HTTP-status or socket errors; conformance checked body bytes, request IDs,
security headers and small-response framing before each sample.

Medians of three samples (ranges are min–max RPS, rounded):

| Workers | Route | Before RPS (range) | After RPS (range) | Median change |
| --- | --- | --- | --- | --- |
| 1 | plaintext | 98,436 (93,989–106,945) | 101,095 (85,514–112,264) | +2.7% |
| 1 | JSON | 98,205 (91,834–99,229) | 91,879 (90,266–92,697) | −6.4% |
| 4 | plaintext | 122,207 (109,697–126,005) | 117,784 (107,507–119,270) | −3.6% |
| 4 | JSON | 104,788 (99,443–112,166) | 104,777 (97,906–118,140) | approximately unchanged |
| 16 | plaintext | 116,685 (113,163–119,258) | 119,987 (113,913–130,315) | +2.8% |
| 16 | JSON | 120,572 (111,784–123,426) | 113,399 (96,336–133,156) | −5.9% |

These results **do not establish a general throughput improvement**. Ranges overlap;
the small-JSON opt-in also has negative median comparisons. Retain buffered responses
for small payloads unless application-specific measurements justify changing them.
The IO adapter adds an allocation and another forwarding call per JSON write; its
main benefit is avoiding the complete intermediate body for larger responses.

Latency medians across the three runs, in milliseconds:

| Workers | Route | After p50 | Before p99 | After p99 |
| --- | --- | --- | --- | --- |
| 1 | plaintext | 0.541 | 1.560 | 1.590 |
| 1 | JSON | 0.643 | 1.750 | 1.810 |
| 4 | plaintext | 0.536 | 3.500 | 2.720 |
| 4 | JSON | 0.613 | 3.150 | 3.890 |
| 16 | plaintext | 0.482 | 3.140 | 2.680 |
| 16 | JSON | 0.529 | 4.450 | 2.320 |

Median latency is sub-millisecond here; **p99 is not**. Increasing workers beyond
the CPU quota is not a demonstrated throughput strategy. A remote fixed-rate load
generator, longer runs, CPU profiles and production TLS/observability are required
before making stronger performance claims or targeting a particular p99 objective.

Response-cycle allocated bytes, median of three invocations of `json_io.cr`:

| Message bytes | Buffered | Direct | Reduction |
| --- | --- | --- | --- |
| 13 | 33,963.7 B | 33,871.1 B | 92.6 B |
| 16,384 | 83,182.6 B | 33,886.9 B | 49,295.7 B (59.3%) |

These cycles deliberately construct and close a fresh HTTP response each time; its
roughly 32 KiB buffer dominates the small-body row. Real keep-alive connections reuse
the server response. The existing whole-request harness measured default-stack
plaintext at approximately **1.44 KiB/request before and after**, with no meaningful
allocation reduction from the scope changes. It measured 2,166 → 2,008 ns/request
for plaintext, 2,985 → 2,928 ns for the parameterized resource and 2,905 → 3,079 ns
for cycling routes. Those tiny timing windows are noisy and likewise show mixed
results; the scope change's concrete architectural benefit is removal of shared
registry locks, not a proven universal speedup.

Validation on the final production source:

- Full suite with PostgreSQL and Redis: **3,391 examples, 0 failures, 0 errors,
  1 pending** (the opt-in two-process scale-out scenario).
- Modern execution contexts and legacy `-Dpreview_mt`, each with 16 workers:
  **31 examples, 0 failures, 0 errors** per scheduler.
- New coverage includes 6,400 interleaved scopes, nested exception cleanup,
  cross-fiber configuration invalidation, JSON escaping/framing/HEAD, bounded
  body reads and 64 clients each making a refused upload followed by two accepted
  POSTs. The two documented Crystal snippets compile.
- Source lint: 179 files, no failures. Formatting, documentation registration
  and relative-link checks pass. Hosted CI status is tracked separately on the pull request.

The service-enabled suite also emits Boehm finalization-cycle warnings. This review
does not establish long-duration leak freedom or zero-GC behavior; keep that as a
separate soak/profiling requirement rather than inferring it from the short tests.

Raw samples, binary hashes, environment metadata and allocation outputs are saved
under `benchmark/results/performance-review/` (git-ignored) and included with the
review artifact. The interrupted premature-flush experiment is named separately
and is excluded from the final tables.
