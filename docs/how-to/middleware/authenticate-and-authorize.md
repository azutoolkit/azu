---
description: "Set up JWT, Bearer, or Authly authentication, declare role and scope rules on endpoints, and audit state-changing requests."
---

# Authenticate and authorize requests

Azu authenticates requests before the router matches a path (so an unauthenticated caller receives `401` and cannot probe which routes exist) and checks role, permission, and OAuth 2.0 scope rules after routing matches (`404` or `405` first, then `403`). Full details of the types and options are in [Authentication and authorization](../../reference/api/auth.md).

<!-- prelude -->
```crystal
require "azu"

struct QueueResponse
  include Azu::Response
  include JSON::Serializable

  getter name : String
  getter actor : String

  def initialize(@name : String, @actor : String)
  end

  def render : String
    to_json
  end
end

struct PurgeQueueRequest
  include Azu::Request

  getter name : String = ""
end
```

## 1. Enable JWT authentication and a role hierarchy by convention

Call `config.auth.jwt` and `config.auth.role_hierarchy` inside `configure`. `role_hierarchy` lists your roles from lowest to highest privilege and sets `GET`/`HEAD` to require the lowest role (`:viewer`) and `POST`/`PUT`/`PATCH`/`DELETE` to require the next role (`:operator`):

```crystal
module MyApp
  include Azu

  configure do |config|
    config.api_defaults!
    config.auth.jwt Azu::Env.secret("JWT_SECRET"),
      issuer: "https://auth.example.com",
      audience: "https://api.example.com"
    config.auth.role_hierarchy :viewer, :operator, :admin
  end
end
```

To check token revocation or account state on every request, pass a block to `config.auth.jwt`:

```crystal
REVOKED_TOKENS = Set{"jti-compromised-1"}

app = Azu::App.new
app.config.auth.jwt(Azu::Env.secret("JWT_SECRET")) do |identity, _context|
  !REVOKED_TOKENS.includes?(identity.token_id || "")
end
```

## 2. Declare access rules and hooks on endpoints

Use the declarative macros inside an `Azu::Endpoint` body to mark routes `public!`, require roles or OAuth 2.0 scopes (`require_role`, `require_scopes`, `require_permissions`), exempt enrolment steps (`enrolment_exempt!`), enable audit logging (`audit!`), or run action hooks (`before_action`):

<!-- prelude -->
```crystal
struct HealthEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/health"
  public!

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

struct PurgeQueueEndpoint
  include Azu::Endpoint(PurgeQueueRequest, QueueResponse)

  post "/api/queues/:name/purge"
  require_role :operator
  require_scopes "queues:purge"
  audit! critical: true
  summary "Purge all jobs from a queue"

  before_action :verify_queue_unlocked

  private def verify_queue_unlocked : Nil
    if params["name"]? == "system"
      forbidden! "The system queue cannot be purged", code: "system_queue_locked"
    end
  end

  def call : QueueResponse
    content_type "application/json"
    QueueResponse.new(name: params["name"], actor: principal!.id)
  end
end
```

Inside `#call` or any `before_action` hook:
- `principal!` (or `current_user!`) returns the authenticated `Azu::Auth::Principal` or raises `401`.
- `role?(:admin)` checks whether the principal satisfies `:admin` (taking `role_hierarchy` into account).
- `scope?("queues:purge")` (or `permission?("queues:purge")`) checks whether the principal holds that scope or permission.
- `authorize!(role: :admin)` or `forbidden!("reason", code: "...")` raises `403` with a stable error code.

## 3. Group routes under a shared scope requirement

When registering routes with `app.routes`, pass role or scope options to `scope` or individual verbs. Options compose in three layers: `scope ▷ endpoint ▷ call-site`:

```crystal
app = Azu::App.new
app.config.auth.bearer({"secret-token" => Azu::Auth::Identity.new("u-1", roles: ["admin"], scopes: ["queues:purge"])})
app.config.auth.role_hierarchy :viewer, :operator, :admin

app.routes do
  endpoint HealthEndpoint

  scope "/v1", role: :viewer do
    endpoint PurgeQueueEndpoint
  end
end
```

## 4. Integrate with Authly (`azutoolkit/authly`)

Azu works directly with [Authly](https://github.com/azutoolkit/authly) for OAuth 2.0 and OpenID Connect:

1. **As a resource server**: pass an `Authly::StrategyTokenVerifier` (or any verifier with `#verify(token : String)`) to `config.auth.authly`. Azu maps `sub` to `principal!.id`, space-delimited `scope` claims to `principal!.scopes` (`require_scopes`), and answers `503 Service Unavailable` with `Retry-After: 1` when the token store raises `VerificationUnavailable`.
2. **As an OAuth 2.0 / OIDC authorization server**: call `mount_authly` inside `app.routes` (or pass `provider: true` to `config.auth.authly`) to mount Authly's `/oauth/*`, `/device`, and `/.well-known/*` endpoints on `Azu::Router` with `public: true` and `csrf_exempt: true` on non-browser endpoints.

```crystal
class CustomTokenVerifier
  def verify(token : String) : Hash(String, JSON::Any)?
    return nil unless token == "valid-access-token"
    JSON.parse(%({"sub":"user-7","cid":"client-1","role":"operator","scope":"queues:read queues:purge"})).as_h
  end
end

app = Azu::App.new
app.config.api_defaults!
app.config.auth.authly CustomTokenVerifier.new, realm: "api"
app.config.auth.role_hierarchy :viewer, :operator, :admin
```

When `require "authly"` is present in your application, `config.auth.authly(audience: "https://api.example.com", provider: true)` builds `Authly::StrategyTokenVerifier.new`, mounts `Authly::Handler.new` (including `POST /oauth/challenge` and `GET|POST /oauth/social/:provider(/callback)`), and configures default `Authly.config.issuance_options` so `challenge_response` grants carry `{"amr" => "challenge_response", "mfa" => true}` and `social` grants carry `{"amr" => "social"}`:

<!-- skip -->
```crystal
require "azu"
require "authly"

MyApp.configure do |config|
  config.api_defaults!
  config.auth.authly audience: "https://api.example.com", provider: true
  config.auth.role_hierarchy :viewer, :operator, :admin
end
```

### MFA via Authly challenge-response and Social Login

Use `require_challenge_response!`, `require_mfa!`, or `require_social!` on endpoints (or `challenge_response: true`, `mfa: true`, `social: :google` on `scope` / route verbs) to enforce step-up MFA or social provider constraints. When a valid token lacks MFA, Azu answers `403 Forbidden` with `code: "mfa_required"` and a `WWW-Authenticate: Bearer error="insufficient_user_authentication"` challenge header so the client knows to initiate `POST /oauth/challenge` and `POST /oauth/token` (`grant_type=challenge_response`):

```crystal
struct WireTransferEndpoint
  include Azu::Endpoint(Azu::Request, QueueResponse)

  post "/api/transfers"
  require_role :operator
  require_scopes "transfers:write"
  require_challenge_response!

  def call : QueueResponse
    content_type "application/json"
    QueueResponse.new(name: "transfer", actor: principal!.id)
  end
end
```

## 5. Record audit events

Register an `on_audit` callback on `config` to receive an `Azu::Instrumentation::AuditEvent` after every state-changing request (`POST`, `PUT`, `PATCH`, `DELETE`) or any route marked with `audit!`:

```crystal
app = Azu::App.new
app.config.on_audit do |event|
  Log.for("audit").info do
    "action=#{event.action} principal=#{event.principal.try(&.id)} status=#{event.status} outcome=#{event.outcome}"
  end
end
```

## See also

- [Authentication and authorization](../../reference/api/auth.md)
- [Protect forms and APIs](protect-forms-and-apis.md)
- [Endpoint](../../reference/api/endpoint.md)
- [Router](../../reference/api/router.md)
