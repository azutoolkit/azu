# Table of contents

- [Overview](README.md)

## Start here

- [Getting started](tutorials/getting-started.md): an endpoint with a validated contract, a page, a test and the dev dashboard, in about 15 minutes.
- [Everything in the box](explanation/features.md): every feature Azu ships, with a link to its guide.
- [FAQ and troubleshooting](faq.md): common questions and the errors you are likely to meet.
- [Migrate to 0.6](how-to/migrate-to-0.6.md): moving from the global `configure` style to `Azu::App`.

## Tutorials

- [Getting started](tutorials/getting-started.md): your first app.
- [Building a user API](tutorials/building-a-user-api.md): a complete JSON CRUD API.
- [Working with databases](tutorials/working-with-databases.md): CQL models, migrations and queries.
- [Adding WebSockets](tutorials/adding-websockets.md): a chat channel with pub/sub.
- [Building live components](tutorials/building-live-components.md): server-rendered views that update in place.
- [Testing your app](tutorials/testing-your-app.md): endpoints, contracts, channels and components.
- [Deploying to production](tutorials/deploying-to-production.md): configuration, secrets and a running service.

## How-to guides

### Endpoints and validation

- [Create an endpoint](how-to/endpoints/create-endpoint.md)
- [Handle parameters](how-to/endpoints/handle-parameters.md): path, query, form and JSON.
- [Return different formats](how-to/endpoints/return-different-formats.md): JSON, HTML, text, XML.
- [Validate requests](how-to/validation/validate-requests.md)
- [Validate models](how-to/validation/validate-models.md)
- [Handle validation errors](how-to/validation/handle-validation-errors.md)
- [Handle file uploads](how-to/file-handling/handle-file-uploads.md) and [validate file types](how-to/file-handling/validate-file-types.md)

### Errors and middleware

- [Handle errors gracefully](how-to/errors/handle-errors-gracefully.md) and [create custom errors](how-to/errors/create-custom-errors.md)
- [Create custom middleware](how-to/middleware/create-custom-middleware.md)
- [Add logging](how-to/middleware/add-logging.md)
- [Use sessions](how-to/middleware/use-sessions.md)

### Templates

- [Render HTML templates](how-to/templates/render-html-templates.md)
- [Use template helpers](how-to/templates/use-template-helpers.md)
- [Enable hot reload](how-to/templates/enable-hot-reload.md)

### Real-time

- [Create a WebSocket channel](how-to/real-time/create-websocket-channel.md)
- [Broadcast messages](how-to/real-time/broadcast-messages.md)
- [Build a live component](how-to/real-time/build-live-component.md)

### Data and caching

- [Define a schema](how-to/database/define-schema.md), [create models](how-to/database/create-models.md), [run migrations](how-to/database/run-migrations.md)
- [Query data](how-to/database/query-data.md) and [handle transactions](how-to/database/handle-transactions.md)
- [Set up a memory cache](how-to/caching/setup-memory-cache.md) and [a Redis cache](how-to/caching/setup-redis-cache.md)
- [Run background jobs](how-to/jobs/background-jobs.md)

### Testing

- [Test endpoints](how-to/testing/test-endpoints.md)
- [Test WebSockets](how-to/testing/test-websockets.md)

### Performance

- [Optimize endpoints](how-to/performance/optimize-endpoints.md)
- [Optimize database queries](how-to/performance/optimize-database-queries.md)
- [Monitor performance in development](how-to/performance/monitor-performance.md)

### Deployment

- [Configure production](how-to/deployment/configure-production.md)
- [Deploy with Docker](how-to/deployment/deploy-with-docker.md)
- [Scale horizontally](how-to/deployment/scale-horizontally.md)
- [Scale real-time features out](how-to/deployment/scale-out-realtime.md)
- [Shut down gracefully](how-to/deployment/graceful-shutdown.md)

## Reference

### Core API

- [Core module](reference/api/core.md), [App](reference/api/app.md), [Router](reference/api/router.md)
- [Endpoint](reference/api/endpoint.md), [Request](reference/api/request.md), [Response](reference/api/response.md)
- [Content negotiation](reference/api/content-negotiation.md), [Streaming and SSE](reference/api/streaming.md)
- [OpenAPI](reference/api/openapi.md), [Testing](reference/api/testing.md)
- [Cache](reference/api/cache.md), [Redis](reference/api/redis.md)
- [Error types](reference/errors/error-types.md)

### Real-time

- [Channel](reference/api/channel.md), [Presence](reference/api/presence.md), [Component](reference/api/component.md)
- [Spark client and reconnects](reference/spark-client.md), [Spark benchmarks](reference/spark-benchmarks.md)

### Handlers, configuration and templates

- [Built-in handlers](reference/handlers/built-in.md)
- [Configuration options](reference/configuration/options.md), [environments](reference/configuration/environments.md), [`Azu::Env`](reference/configuration/env.md)
- [Template engine](reference/templates/engine.md), [template helpers](reference/templates/helpers.md)

### Database

- [CQL bridge](reference/api/cql-bridge.md), [database dashboard](reference/database-dashboard.md)
- [CQL API](reference/database/cql-api.md), [query methods](reference/database/query-methods.md), [validations](reference/database/validations.md)

### Releases

- [Breaking changes](reference/breaking-changes.md): what changed in each version and how to adapt.

## Explanation

- [Everything in the box](explanation/features.md)
- [Architecture overview](explanation/architecture/overview.md), [request lifecycle](explanation/architecture/request-lifecycle.md), [type safety](explanation/architecture/type-safety.md), [performance design](explanation/architecture/performance-design.md)
- [Endpoints](explanation/concepts/endpoints.md), [contracts](explanation/concepts/contracts.md), [middleware](explanation/concepts/middleware.md), [real-time](explanation/concepts/real-time.md), [components](explanation/concepts/components.md), [Spark live views](explanation/spark-live-views.md)
- [Why contracts?](explanation/design-decisions/why-contracts.md) and [why type safety?](explanation/design-decisions/why-type-safety.md)

## Contributing

- [Development setup](contributing/setup.md), [code standards](contributing/standards.md), [roadmap](contributing/roadmap.md)
- [Benchmarks](../benchmark/README.md): how Azu is measured against other frameworks.
