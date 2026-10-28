# Azu v1 release review

This change prepares Azu for a v1 review; it does not publish 1.0.0 or certify a deployment.
The base release is 0.10.5. The release workflow owns version numbers: after review and
successful CI, a release commit containing `(MAJOR)` requests the major bump. Do not manually
edit `shard.yml` or tag a release from this workspace.

## Changes requiring review

- Forwarded host and scheme now have one trust boundary across CSRF, WebSocket origin checks,
  template helpers and automatic HSTS. Only configured IP/CIDR peers may supply them. Five new
  regressions failed against the previous implementation and passed with the fix.
- Static files and directory indexes resolve symlinks before serving them. Targets outside the
  public root or within an excluded path are refused, and listings omit excluded names and aliases.
  The public root itself can still be a deployment symlink. Public files must remain controlled by
  the deployment; path validation is not protection against concurrent untrusted filesystem writes.
- Releases depend on Spark client tests and reproducible generated artifacts, in addition to the
  existing Crystal and documentation gates. Non-release CI jobs have read-only repository access;
  only the release job receives write permission.
- Session guidance now requires pooled Redis connections and an inner rescuer after the session
  handler. The runnable `playground/redis_sessions` example pins the tested session revision and
  exercises real Redis persistence, CSRF, error-response cookie preservation and concurrent visitors.
  Both Crystal CI jobs run this isolated integration suite before release.
- Opt-in `azu-ecr` and `azu-min-ecr` benchmark fixtures render the exact shared ECR template through
  Azu's existing endpoint/response path. The default benchmark continues to use Crinja.

## Deployment migration

List the reverse proxy's exact address or CIDR in `TRUSTED_PROXIES`, and configure it to overwrite
`X-Forwarded-Host` and `X-Forwarded-Proto`. Missing peers, UNIX sockets and unlisted addresses do not
establish proxy trust. Each application's default stack captures that application's proxy list.
Keep assets within the public root instead of linking to files elsewhere. See the updated
[breaking changes](docs/reference/breaking-changes.md) and
[production configuration](docs/how-to/deployment/configure-production.md).

## Validation

Local validation uses Crystal 1.22.1, Node 24, PostgreSQL 17 and Redis 8. Hosted CI uses PostgreSQL 16,
Redis 7, Node 22 and both the pinned and latest Crystal compiler; those exact CI environments must
still run before release. Logs are retained under `/workspace/setup/logs` in the prepared environment.

- Proxy/security compatibility suite after the fix: 109 examples, no failures/errors/pending.
- Static-file suite after the fix: 339 examples, no failures/errors/pending.
- Combined CSRF/body/throttle regression check: 181 examples, no failures/errors/pending.
- Threaded CI selection: 23 examples, no failures/errors/pending.
- Spark: 269 tests pass; build and TypeScript declarations pass; generated files have no diff.
- Ameba: 178 files, no findings. Formatting and whitespace checks pass.
- Playground application builds and all playground examples type-check.
- Documentation inventory and links pass (108 files, no problems or unlinked pages).
- Documentation compilation: 661 snippets, zero failures.
- Optimized production build and smoke checks pass: health JSON, request IDs, security headers,
  ignored untrusted forwarded scheme, sanitized error response, and clean SIGTERM exit.
- Final full suite, with PostgreSQL, Redis and cross-process scaling enabled: 3,375 examples,
  zero failures, zero errors and zero pending. The focused configuration/query-cache selection
  also passes all 27 examples.
- Redis session example: frozen dependency install and executable build pass; all 3 real Redis
  integration examples pass. Removing the inner rescuer produces the expected cookie-preservation
  failure; restoring it passes. The updated guides compile (9 checked snippets), all 108 documentation
  files pass link checks, and all 401 repository Crystal files pass formatting.

## Local deployment and performance evidence

The disposable local deployment used Nginx TLS, two production-mode Azu processes, encrypted Redis
sessions and PostgreSQL. All 45 readiness checks passed, covering proxy trust, authentication/session
behavior, coordinated key replacement, dependency outages, logical backup/restore, SQL migration
locking/rollback, local telemetry and graceful shutdown. This validated the tested topology, not an
external application or identity provider. Two configuration findings are now documented and exercised
by the Redis example: a shared unpooled connection failed concurrent session reads, and rendering an
endpoint error outside session middleware replaced the authenticated cookie.

The extended mixed workload completed 305,818 measured requests and retained all 15,289 acknowledged
writes, with zero request errors. The 64-client, 128-client and 64-client soak stages **failed** the
provisional p95 <=250ms target (255.91ms, 370.62ms and 272.03ms). The 16-client recovery stage returned
to p95 35.51ms. CPU quota throttling and a sequential scan in the sample application's count query were
observed. These results do not establish maximum framework capacity or a production SLO.

The framework comparison completed 120 repetitions and 43,321,560 requests without errors; 18 of 24
rows exceeded 5% relative standard deviation. The separate same-session template comparison completed
35 repetitions and 13,276,721 requests without errors. Default-stack Azu ECR had median throughput
50,178 requests/s versus Crinja's 11,034 (4.55x), and median-run p99 2.35ms versus 9.74ms. These are
indicative shared-machine observations with the driver's noise flag retained, not framework rankings
or publishable dedicated-machine benchmark claims. ECR and Crinja were measured with the same default
middleware; the other ECR fixtures used the same template. Competitor versions were repository pins.

The committed [evidence summary](release/v1-evidence.json) records run IDs, source identities, counts,
checks and limitations. The larger raw logs/JSON, source patches and charts are retained in the prepared
environment under `/workspace/setup/azu-live-readiness`, `/workspace/setup/framework-compare` and
`/workspace/setup/framework-ecr`. The original full-suite result above is for the hardened framework
commit; hosted checks must still run on the final reviewed commit including these documentation,
example and benchmark additions.

## Release gates

- [x] Resolve configuration/CQL and static-file pending cases; full framework suite has zero pending.
- [x] Document the observed Redis/session error-handling requirements and add a runnable integration example.
- [x] Add and validate the compiled ECR benchmark variants; preserve noisy/failed performance outcomes.
- [x] Commit and push the finalized release-review changes on `codex/azu-v1-hardening`.
- [ ] Open/update the release PR and obtain review of the proxy/static-file migrations and session guidance.
- [ ] Require successful hosted `test`, `test-latest`, `test-mt`, `spark-client` and `docs` checks on the reviewed commit.
- [ ] Merge while preserving `(MAJOR)` in the release-triggering commit message.
- [ ] Verify the automated version commit, `v1.0.0` tag and published GitHub release.

The workflow owns the version bump. Do not push directly to master, manually tag, or treat local results
as a substitute for unavailable hosted check/review status.

## Deployment requirements outside this release

A green local run is evidence for framework behavior, not an enterprise certification. Before
publishing, require hosted CI on the reviewed commit and review the migrations above. Applications using
the release must validate their own TLS/proxy topology, secret rotation, authentication/session integration,
backups and recovery, database migration procedure, observability and load/latency objectives.
Any contractual support window, compliance standard or SLA must be agreed by the maintainer;
this patch introduces no such commitments. Browser acceptance testing and an independent security
review have not been performed in this task.

The former configuration and CQL pending cases are now executable regressions. Configuration checks
verify independent production/staging instances and restore the process environment. The CQL test uses
channels to hold one request open while another completes, checking both request IDs and counters.
Development/CI require CQL 0.0.925 or newer. Request-cache diagnostics reject older process-wide tracker
implementations at construction; a compatibility probe against CQL 0.0.578 confirmed rejection without
resolving a lazy provider, while ordinary middleware still initialized. The static-file pending cases
were also replaced by active tests.

Live deployment validation is deferred at the user's request. No live application's infrastructure or
operational guarantees are claimed by this review.
