# Development Roadmap

Where Azu is heading and where contributions help most. This page lists directions, not promises: there are
no dates, and no API on this page exists unless the [API reference](../reference/api/core.md) documents it.

## Where Azu stands

The 0.6 work is described in [Breaking Changes](../reference/breaking-changes.md#unreleased-06-work):

- `Azu::App` is an application as a value (configuration plus router), with `routes` and `mount`.
- Request contracts answer `422` when validation fails.
- A default handler stack, graceful shutdown (`config.shutdown_timeout`) and an opt-in dev dashboard
  (`require "azu/dev"`).
- `require "azu"` starts nothing; `Azu.setup_logging` is explicit.

## Directions

These are areas where work is wanted. Open an issue before starting anything large.

### Correctness and performance

- Cache compiled templates (they are read again on every render today).
- Resolve template and error-page paths relative to the application, not the working directory.
- Measure before optimizing: [Performance Design](../explanation/architecture/performance-design.md) explains
  how the numbers on that page were taken.

### Developer experience

- Better compile-time error messages from the endpoint and contract macros.
- More generator support in the [Azu CLI](https://github.com/azutoolkit/azu_cli).
- Documentation that is type-checked in CI: every Markdown file with a `crystal` block is compiled by
  `scripts/check_docs.cr`.

### Possible additions

Ideas that have been discussed but have no design or code yet: GraphQL support, service discovery helpers,
event sourcing helpers. They would live in separate shards where possible, so the core stays small.

## Release process

Azu follows semantic versioning in spirit: patch releases fix bugs, minor releases add features, and anything
that breaks an API is listed in [Breaking Changes](../reference/breaking-changes.md) with a migration.

## Where to start

Good first contributions are listed on the GitHub issue tracker. Typical ones:

- Add or fix a specification in `spec/` for behaviour that is not covered yet.
- Fix a documentation page whose snippet no longer compiles (run `scripts/check_docs.cr` on it).
- Improve an error message.

## Next Steps

- [Development Setup](setup.md) - Set up your development environment
- [Code Standards](standards.md) - Learn coding guidelines
