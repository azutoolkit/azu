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

- Baseline full suite: 3,369 examples, no failures/errors, five pending.
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
  zero failures/errors, two pre-existing pending cases (listed below).

## Release requirements outside this patch

A green local run is evidence for framework behavior, not an enterprise certification. Before
publishing, require hosted CI on the reviewed commit and review the migrations above. Validate the
actual deployment's TLS/proxy topology, secret rotation, authentication/session integration,
backups and recovery, database migration procedure, observability and load/latency objectives.
Any contractual support window, compliance standard or SLA must be agreed by the maintainer;
this patch introduces no such commitments. Browser acceptance testing and an independent security
review have not been performed in this task.

Two pre-existing pending tests need explicit disposition: the environment-variable configuration
case and the optional CQL concurrent request-cache integration case. The latter is documented by
the test as depending on CQL's cache scoping; do not claim isolation across the supported CQL
version range until that integration test is enabled and passes. The static-file pending cases
were replaced by active tests in this patch.
