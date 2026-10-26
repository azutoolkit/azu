# Documentation overhaul: audit and plan

The docs are 94 pages and about 30 000 lines. Every page was read against `src/` (and `lib/cql` for the database
pages), so this plan rests on what the code does today, not on what the pages say. Readers get three
things: one structure to navigate by, one style to read, and pages that are correct and contain no padding.

## What the audit found

| Problem | Scale | Example |
|---|---|---|
| Factual errors | 60+ verified (list below) | Three testing pages say `Azu::Testing` does not exist and hand-roll a test server; the Docker guide sets `AZU_ENV`, which nothing reads, so the container listens on 127.0.0.1 |
| Insecure examples | 7 pages | `ENV.fetch("SPARK_SECRET", "development-only-secret")` bypasses the production guard and signs with a public key |
| The sidebar is broken for GitBook | `SUMMARY.md` | Several pages share one list item (Core module, App and Router are three links on one line): GitBook takes one page per item, so App, Router, Request, Response, Presence and more are probably missing from the navigation. Three pages are listed twice; one entry points outside `docs/` |
| Duplication | ~25 clusters | The default handler stack is written out in 8 places, the problem-body JSON in 4, the Spark lifecycle in 3 |
| Repeated boilerplate | ~40% of some pages | `scripts/check_docs.cr` compiles each block alone, so pages redefine the same schema, model or five empty channel callbacks in every block |
| Wrong section | ~20 pages | A feature inventory under Explanation, generic Docker/nginx/K8s compendia under How-to, a Jinja tutorial under Reference, a changelog inside an explanation page |
| Inconsistent style | all sections | Three title styles ("How to Set Up Memory Cache", "How to run background jobs", "Use Sessions"); "See also" / "See Also" / "Where next" / none; "This guide shows you how to…" openings; lab-notebook voice ("was run", "came back 35 bytes"); banners ("Your API is ready!") |
| Undocumented API | 8 modules | `Azu::Templates`/`Renderable`, Spark configuration (nine `SPARK_*` variables), `Azu::PubSub` (lives inside channel.md), `HandlerPipeline`, `Clock`, `Instrumentation`, `SessionAdapter`, `Markup` |

## Style guide

The rules every page follows (sections, titles, openings and endings, voice, code examples, the reference page
layout, one owner per topic) are in [Documentation style](../contributing/docs-style.md). Phase 0 adds that page;
the phases below apply it.

## Phase 0: enablers (small, first)

1. **Page prelude for `scripts/check_docs.cr`.** A block marked `<!-- prelude -->` is prepended to every later
   block of the same file. Its types are not body-checked a second time. This lets a page define its schema,
   model or channel once.
2. **`SUMMARY.md` rebuilt.**
   - One link per item, with nesting for groups.
   - Every page under `docs/` listed exactly once.
   - Nothing outside `docs/`: Benchmarks becomes a link inside the contributing page.
3. **Sidebar check.** `scripts/check_doc_links.cr` also fails when:
   - a page is missing from `SUMMARY.md` or listed twice;
   - an item holds more than one link;
   - a page's H1 differs from its sidebar label.

   This stops the sidebar from drifting again.
4. **[Documentation style](../contributing/docs-style.md).** The style guide, so reviewers and future pages have one rule set.

## Phase 1: correctness (no page moves, no URL changes)

Fix every verified error below in place, including the insecure examples. This phase is worth shipping on its
own: each fix is small, and every page stays where it is. The checks run per commit.

**Testing**
- Three pages say `Azu::Testing` does not exist and hand-roll servers: `tutorials/testing-your-app.md:25`,
  `how-to/testing/test-endpoints.md:7`, `test-websockets.md:8`. The module ships (`src/azu/testing/`).
  Rewriting these pages is phase 3; phase 1 removes the false statement and links the reference.
- Several pages say WebSockets are not drained on stop: `test-endpoints.md:474`, `configure-production.md:161`,
  `testing-your-app.md:523`. They are sent a 1001 close and waited for (`app.cr:132-158`).

**Contracts and errors**
- These pages say `Rescuer` or the router answers contract 400/422:
  - `request-lifecycle.md:104` (its printed output is wrong: run, it prints `B out (422)`);
  - `contracts.md:192`, `request.md:309`, `response.md:181`, `error-types.md:97`.

  The endpoint renders them itself (`handler/endpoint.cr:79-83, 336-347`). For the same reason the custom
  `ValidationError` handlers in `handle-validation-errors.md:161` and `handle-errors-gracefully.md:62` never
  see contract failures.
- `handle-validation-errors.md:52`, `migrate-to-0.6.md:290`: without `Accept` (or with `*/*`) the error body is
  `text/plain`, not JSON (`response.cr:247-270`).
- `validate-requests.md:107`: a second `validate age, …` replaces the first, so `gt: 0` is dropped
  (`schema/validation.cr:24`).
- `handle-parameters.md:61`: the lookup order is path, query, then form (`params.cr:23-31`).
- Ranges that disagree with their messages: `building-a-user-api.md:159`, `why-contracts.md:137`.
- `faq.md:11`: the "caught at compile time" overclaim; input validation runs per request.

**Templates**
- `{{ csrf_field() }}`, `flash` and `current_path` are empty when `view` is called from a response. They are
  injected only when the rendering type has `context` (`templates.cr:119`). This affects
  `render-html-templates.md:225`, `use-template-helpers.md` and `use-sessions.md`. Pass the token in, as
  `azu new` does.
- `helpers.md`:
  - :44 `form_tag` adds no CSRF token;
  - :568 the helper prefix is `v1_user`, not `api_v1_user`;
  - :761 `number_to_human` gives "1.2 thousand".
- `use-template-helpers.md`:
  - `checkbox(required=)` does not exist;
  - `rel=noopener` is added only with `target=_blank`;
  - `l("date.short")` does not read `date.formats.short`;
  - nothing reads `?locale=`;
  - endpoint helpers are not type-safe without `id`.
- `engine.md:159`: `include … with x=y` is invalid. `engine.md:265, 277`: there is no `empty` test.
- `enable-hot-reload.md`: says `azu serve` where the CLI's watcher is `azu dev`; it registers the reload channel
  unconditionally while the text says development only.

**Real-time and Spark**
- Hard-coded secret fallbacks:
  - `SPARK_SECRET` in `building-live-components.md:142`, `build-live-component.md:68`, `component.md:290`;
  - `CHANNEL_TOKEN "change-me"` in `real-time.md:284`, `channel.md:143`, `create-websocket-channel.md:255`;
  - `environments.md:200`.
- "Production refuses to start without `SPARK_SECRET`" (`spark-live-views.md:144`,
  `building-live-components.md:150`): the check runs at the first token, not at boot.
- `spark-client.md:654`: snapshots expire with `snapshot_ttl`, not `token_ttl`.
- `real-time.md:242`: port 3000; the default is 4000.

**Configuration and deployment**
- `deploy-with-docker.md`:
  - `AZU_ENV` (nothing reads it), so the container stays in development and binds 127.0.0.1;
  - Crystal 1.17.1;
  - `REDIS_URL` for the cache (it reads `CACHE_REDIS_URL`, `cache.cr:600`);
  - `COPY views/`.
- `configure-production.md`:
  - :20 HOST defaults to 127.0.0.1 in development;
  - :51-59 the CSRF handler reads `CSRF_SECRET` itself and refuses production without it (`csrf.cr:144`).

  The same CSRF claim is in `scale-horizontally.md:24`.
- `deploying-to-production.md:60`: `Static` falls through by default (`static.cr:99`).
- Tutorials re-read PORT/HOST/SHUTDOWN_TIMEOUT that Azu already reads, and default HOST to 0.0.0.0 over the
  development loopback default.
- Handler order Rescuer-before-Logger: `working-with-databases.md`, `adding-websockets.md`, `create-endpoint.md:225`.
- `options.md:306` "every variable is listed": missing `AZU_STRICT_ENVS`, `KUBERNETES_SERVICE_HOST`,
  `CSRF_SECRET`, two `PERFORMANCE_*` and all `SPARK_*`.
- `core.md:218`: the reader is `template_hot_reload?`.
- `monitor-performance.md:37` builds a second `PerformanceMonitor`; the dashboard reads
  `CONFIG.performance_monitor`.

**Cache and database** (CQL 0.0.798 is what Azu locks; the pages describe 0.0.536/0.0.604)
- `hit_rate` is hits ÷ lookups, not fill level: `cache.md:68`, `setup-memory-cache.md:208`.
- Declared indexes are created: `define-schema.md:76, 186`, `run-migrations.md:38`, `optimize-database-queries.md:11`.
- `preload` works for `belongs_to` and `has_one`: `create-models.md:174`, `query-data.md:383`,
  `optimize-database-queries.md:136`, `query-methods.md:296`, `database-dashboard.md:116`.
- `dependent:` is applied by `delete!`: `create-models.md:171`, `working-with-databases.md:521`, `cql-api.md:299`,
  `database-dashboard.md:116`.
- `where(col: nil)` is `IS NULL`: `query-data.md:135`, `query-methods.md:134`.
- A nested `transaction` is a SAVEPOINT on the same connection: `cql-bridge.md:186`.
- `validations.md:33`: `on:` is supported. `cql-api.md:554`: `azu/cql` does translate errors to 422.
- Pool advice ignores CQL's engine pool, the default for `postgres://`: `optimize-database-queries.md:416`,
  `configure-production.md:166`.
- Migrations live in `src/db/migrations` (CLI), not `db/migrations`; the docs should lead with `azu db:*`.

**Reference and project pages**
- `response.md:43`: "Azu ships one response type" ignores Negotiable, Stream, EventStream and NotAcceptable.
  The 406 is missing from three status tables.
- `router.md:263`: shows the legacy 404 body.
- `breaking-changes.md`:
  - :694 `Azu.start` without arguments exists;
  - :689 there is no `Handler::Base#next`;
  - :563 there is no `EmptyRequest`;
  - :717 links point to `azutopia/azu` and a missing CHANGELOG.
- `performance-design.md:39, 236` and `optimize-endpoints.md:10`: class endpoints are `dup`ed per request.
- `return-different-formats.md`: negotiates by hand; `Azu::Response::Negotiable` does it (q-values, 406, `Vary`).
- `add-logging.md:270`: Logger already redacts credential query values (`Azu::Env.redact_url`).
- `migrate-to-0.6.md:218`: `app.server` without arguments has no handlers; only `start` adds the defaults.
- `roadmap.md`:
  - lists template caching and type-checked docs as future work; both are done;
  - its release process is wrong (every green master push releases).
- `standards.md:3`: Ameba is not run in CI.
- `faq.md:531, 541, 564`: wrong link targets, and `--stats` is compiler statistics.
- `request-lifecycle.md:22`: the graceful-shutdown link points to breaking-changes.

## Phase 2: structure (pages move; URLs change)

| Change | Pages |
|---|---|
| Merge | `architecture/type-safety` + `design-decisions/why-type-safety` → `explanation/type-safety.md`; `why-contracts` into `concepts/contracts.md`; `reference/api/core.md` into `app.md` as an "Azu module" table; `how-to/validation/validate-models` into `how-to/database/` |
| Split | `reference/api/channel.md` → `channel.md` + new `pubsub.md`; `component.md` → `component.md` + new `spark.md` (server API and a config table with every `SPARK_*`); `spark-client.md` → reference / explanation / contributing; `handle-errors-gracefully` (resilience patterns removed) |
| Move | `explanation/features.md` → Start here as *Features*; `spark-benchmarks.md` → contributing; Spark changelog in `spark-live-views.md` → breaking-changes; tutorial deployment steps 5-8 → `how-to/deployment`; loose `reference/*.md` into folders; `cql-bridge` + dashboard setup → `reference/api/cql.md` |
| Fold | `scale-out-realtime` into `scale-horizontally` (presence details to the Presence reference) |
| New | `reference/templates/renderable.md` (`view`, `page_path`, injected variables, lookup, autoescape) |
| Owners | default handler stack → App; error bodies and statuses → Error types; params precedence → Request; test harness → Testing; negotiation → Content negotiation; helpers → Template helpers; deployment walkthrough → the tutorial, env table → Configuration options |

Moved pages get GitBook redirects so outside links keep working.

## Phase 3: rewrites (the large pages)

| Page | Rewrite as |
|---|---|
| `tutorials/testing-your-app`, `how-to/testing/*` | `Azu::Testing::Client`, `Client#connect` and `Spark::Testing` |
| `tutorials/working-with-databases` | One growing app on `Azu::CQL.schema`, what `azu new` generates (729 lines, schema written out 7 times) |
| `how-to/database/query-data`, `optimize-database-queries` | Four or five tasks each; the API catalogue goes to Query methods |
| `how-to/deployment/deploy-with-docker` | Built around `azu new --docker`; the generic Docker/nginx/registry sections go |
| `how-to/deployment/scale-horizontally` | A per-process state checklist with links |
| `reference/templates/engine.md` | What Azu adds to Crinja; Jinja syntax links to the Crinja docs |
| `reference/templates/helpers.md` | One signature table per helper group (1058 lines today), with the missing helpers added |
| `reference/breaking-changes.md` | A per-release changelog; the 520-line "Unreleased" block is split up |
| `reference/database/*` | Re-baselined on the CQL version Azu locks |
| `faq.md` | Short answers, plus a symptom → page table; copied code is removed |
| `how-to/endpoints/create-endpoint`, `validate-requests`, `handle-validation-errors`, `enable-hot-reload`, `use-template-helpers` | One task each |

## Phase 4: consistency sweep

Apply the style guide to every page: titles, openings, `See also`, voice and heading depth. It is mostly
mechanical; the sidebar check from phase 0 enforces the titles.

## Found in passing (code, not docs; to file as issues)

- `Renderable#view` from a response injects no `csrf_token`, `flash` or `current_path`. Every form page has to
  pass the token in by hand.
- The Spark secret check runs lazily, at the first token sign, so a misconfigured production app starts.
- The doc comment at `src/azu/configuration.cr:20-37` shows API that does not exist (`c.template.path`,
  `c.cache.enabled`).
- In CQL, `before_validation` and `after_validation` both run before `validate!`.
- No workflow runs Ameba, although the standards say it is enforced.

## Delivery

- Each phase is one PR, or a few per section in phase 3, and each is green on the `docs` CI job.
- The phases build on each other: 0 makes 1 and 3 shorter, and 1 is safe to ship alone.
- Rough size: phase 0 is small, phase 1 is about 60 small fixes, and phases 2 and 3 are the bulk of the work.
