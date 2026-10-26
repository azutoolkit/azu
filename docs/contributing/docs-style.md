# Documentation style

These are the rules every page under `docs/` follows. A reader who knows them can guess where a fact lives
and what a page will contain. CI enforces the mechanical ones (see [Checks](#checks)); review enforces the rest.

## Sections

The docs follow [Diátaxis](https://diataxis.fr). A page does one of four jobs, and its section decides its shape.

| Section | Folder | The page | Shape |
|---|---|---|---|
| Tutorials | `tutorials/` | teaches by building one thing, in order | numbered steps; every step runs; ends with `## Next steps` |
| How-to guides | `how-to/` | gets one task done | goal, steps, result; no theory beyond a sentence |
| Reference | `reference/` | states exact facts | the [reference layout](#reference-pages); tables over prose |
| Concepts | `explanation/` | explains why and how it fits together | prose and diagrams; no option tables, no step lists |

A page that does two of these jobs is split, and the parts link to each other.

## Titles

- Write titles in sentence case. The page's `# ` heading and its sidebar label in `SUMMARY.md` are the same text.
- How-to: an imperative, with no "How to" prefix: *Create an endpoint*, *Set up a Redis cache*.
- Reference: the name of the thing, with no "Reference" suffix: *Endpoint*, *Configuration options*.
- Concepts: a noun phrase: *Contracts*, *Request lifecycle*.
- Headings inside a page are sentence case too, and stay at `##` and `###`.

## Openings and endings

- The first paragraph says what the reader gets from the page, in one or two sentences. Do not open with
  "This guide shows you how to…" or "This document explains…".
- A how-to page with prerequisites says so right after the opening: `Before you start: …`.
- The last section is `## See also`, with 2 to 4 links, preferably to other sections (a how-to links its
  reference and its concept page). Tutorials end with `## Next steps` instead.

## Voice

- State what the code does, in the present tense. Facts about speed need a measurement and its method, or a
  link to [the benchmark suite](https://github.com/azutoolkit/azu/blob/master/benchmark/README.md).
- Do not use marketing adjectives ("blazing fast", "powerful", "robust"), comparisons with other frameworks or
  languages, banners ("Your API is ready!") or recap lists ("Key takeaways").
- Do not write in a lab-notebook voice ("this was run", "came back 35 bytes", "in this checkout"), and do not
  mention Azu's own specs or the docs checker.
- Changes between versions go in [Breaking changes](../reference/breaking-changes.md) only. Other pages
  describe the current behavior.

## Code examples

- **One app style.** Single-app examples use the facade that `azu new` generates:
  `module MyApp; include Azu; configure do |config| … end; end` and `MyApp.start`. Use `Azu::App.new` only
  where the page is about apps, mounting or tests.
- **Handler order.** A handler array follows the default stack: `RequestId`, `Logger`, `Rescuer`, then the rest
  (see [App](../reference/api/app.md)).
- **Secrets.** Read secrets through the variable Azu reads itself (`CSRF_SECRET`, `SPARK_SECRET`) or through
  `Azu::Env.secret`. Never write `ENV.fetch("NAME", "literal")`: the fallback ships to production.
- **Templates** end in `.jinja`.
- **Define once.** Each type is defined once per page. A page that builds on earlier code marks the shared
  block with `<!-- prelude -->` on the line before its fence; the checker then prepends it to every later block
  of the page. `<!-- skip -->` marks a fragment that cannot compile on its own; use it sparingly, since
  skipped code is not checked.
- **Behavior is run, not assumed.** A status code, an order, a header or an output shown on a page comes from
  running the code, and the page shows the real output.
- **Cite only what exists.** Every class, method, option and environment variable a page names exists in
  `src/` (or in the shard the page is about).

## Reference pages

Every reference page has these sections, in this order. Leave out the ones that have nothing in them.

1. A summary paragraph: what it is, the `require` line it needs, and what it is not.
2. One minimal example.
3. `## API`: a constructor parameter table (name, type, default, meaning), then a method table (signature,
   returns, notes).
4. `## Options`: option, type, default, environment variable.
5. `## Behavior`: exact semantics, the errors it raises, statuses, ordering.
6. `## Limits`: what it does not support.
7. `## See also`.

[Redis](../reference/api/redis.md) is the model page.

## One owner per topic

A fact is written on one page, and other pages link to that page instead of restating the fact. For
example, the default handler stack lives on [App](../reference/api/app.md), error bodies and statuses on
[Error types](../reference/errors/error-types.md), and the test client on [Testing](../reference/api/testing.md).

## Adding a page

1. Write it in its section's folder, with a title that follows the rules above.
2. Add it to `docs/SUMMARY.md` (one item, labelled with its title) and link it from `docs/README.md`.
3. If it has `crystal` blocks, add it to `docs/.checked`.
4. Run the checks.

## Checks

```bash
crystal run scripts/check_docs_listed.cr   # every page with crystal blocks is in docs/.checked
crystal run scripts/check_doc_links.cr     # links, anchors, the sidebar, and links from the landing page
crystal run scripts/check_docs.cr -- $(grep -v '^#' docs/.checked)   # every listed crystal block compiles
```

The link check also fails when a page under `docs/` links outside it with a relative link, because GitBook
publishes `docs/` only. To link a file elsewhere in the repository, use its GitHub URL
(`https://github.com/azutoolkit/azu/blob/master/<path>`); the check still verifies that the file exists.

## See also

- [Code standards](standards.md)
- [Development setup](setup.md)
