require "../spec_helper"

module EndpointDslSpecFixtures
  struct TextOut
    include Azu::Response

    getter text : String

    def initialize(@text : String)
    end

    def render
      @text
    end
  end

  # Reusable policy module that sets auth requirements, audit convention, and a before_action hook.
  module OperatorPolicy
    macro included
      require_role :operator
      audit! critical: true
      before_action :verify_not_frozen
    end

    private def verify_not_frozen
      if header["X-Queue-Frozen"]? == "true"
        conflict!("Queue is currently frozen", code: "queue_frozen")
      end
    end
  end

  module Api
    module Queues
      # Struct endpoint with constructor dependency injection AND declarative route/auth/hygiene/hook DSL.
      struct PurgeEndpoint
        include Azu::Endpoint(Azu::Request, TextOut)
        include OperatorPolicy

        post "/queues/:name/purge"

        summary "Purge a queue"
        description "Removes all pending jobs from the named queue."
        require_permissions "queues:purge"
        max_body_size 1024
        content_types "application/json"

        getter store : Array(String)

        def initialize(@store : Array(String))
        end

        def call : TextOut
          name = params["name"]
          not_found!("Queue #{name} does not exist", code: "queue_not_found") unless @store.includes?(name)
          TextOut.new("purged:#{name}:by:#{current_user!.id}")
        end
      end

      struct ListEndpoint
        include Azu::Endpoint(Azu::Request, TextOut)

        get "/queues"
        summary "List all queues"

        def initialize(@store : Array(String))
        end

        def call : TextOut
          TextOut.new(@store.join(","))
        end
      end
    end
  end

  struct PublicHealthEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    get "/healthz"
    public!
    no_audit!
    summary "Health check"

    def call : TextOut
      TextOut.new("ok")
    end
  end

  struct EnrolmentStepEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    post "/enrolment/mfa"
    require_role :viewer
    enrolment_exempt!
    csrf_exempt!

    def call : TextOut
      TextOut.new("enrolled:#{principal!.id}")
    end
  end

  struct MultiRouteEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    get "/multi-items", role: :viewer, summary: "List multi items"
    post "/multi-items", role: :operator, permissions: ["items:write"], summary: "Create multi item"

    def call : TextOut
      TextOut.new("multi:#{method.to_s.upcase}")
    end
  end

  struct LifecycleHooksEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    post "/hooks-demo"
    public!

    around_action :wrap_outer, :wrap_inner
    before_action :step_one, :step_two
    after_action :inspect_result, :finalize_trace

    def initialize(@log : Array(String))
    end

    private def wrap_outer(&)
      @log << "around_outer:before"
      yield
      @log << "around_outer:after"
    end

    private def wrap_inner(&)
      @log << "around_inner:before"
      yield
      @log << "around_inner:after"
    end

    private def step_one
      @log << "before:one"
      if header["X-Halt"]? == "true"
        halt!(202, "halted-early", HTTP::Headers{"X-Halted" => "yes"})
      end
      if header["X-Bad"]? == "true"
        bad_request!("Bad header value", code: "bad_header")
      end
      if header["X-Invalid-Field"]? == "true"
        unprocessable!("limit", "must be positive")
      end
    end

    private def step_two
      @log << "before:two"
      if required_perm = header["X-Require-Perm"]?
        authorize!(permissions: [required_perm], message: "Missing dynamic permission", code: "dynamic_perm_denied")
      end
    end

    def call : TextOut
      @log << "call"
      TextOut.new("done")
    end

    private def inspect_result(res : TextOut)
      @log << "after:result=#{res.text}"
      header("X-After-Result", res.text)
    end

    private def finalize_trace
      @log << "after:final"
    end
  end

  class BaseAdminEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    require_role :admin
    before_action :record_base

    private def record_base
      header("X-Base-Hook", "ran")
    end

    def call : TextOut
      TextOut.new("base")
    end
  end

  class SubAdminAuditEndpoint < BaseAdminEndpoint
    get "/admin/sub-audit"
    require_permissions "admin:audit"
    before_action :record_sub

    private def record_sub
      header("X-Sub-Hook", "ran")
    end

    def call : TextOut
      TextOut.new("sub")
    end
  end

  class SiblingAdminEndpoint < BaseAdminEndpoint
    get "/admin/sibling"
  end

  struct MockClaims
    getter payload : Hash(String, JSON::Any)

    def initialize(@payload : Hash(String, JSON::Any))
    end
  end

  class MockAuthlyVerifier
    def verify(token : String) : MockClaims?
      case token
      when "valid-scoped"
        MockClaims.new(JSON.parse(%({"sub":"u-99","cid":"cli-1","role":"viewer","scope":"data:read data:export"})).as_h)
      when "missing-scope"
        MockClaims.new(JSON.parse(%({"sub":"u-99","cid":"cli-1","role":"viewer","scope":"other:scope"})).as_h)
      when "social-google-factor1"
        MockClaims.new(JSON.parse(%({"sub":"u-social-1","cid":"social:google","role":"operator","scope":"transfers:write","amr":["social"],"social_uid":"g-1001","email":"dev@example.com","email_verified":true})).as_h)
      when "social-github-factor1"
        MockClaims.new(JSON.parse(%({"sub":"u-social-2","cid":"social:github","role":"operator","scope":"transfers:write","amr":["social"],"social_uid":"gh-2002","email":"octo@example.com","email_verified":true})).as_h)
      when "mfa-challenge-verified"
        MockClaims.new(JSON.parse(%({"sub":"u-social-1","cid":"cli-1","role":"operator","scope":"transfers:write","amr":["social","challenge_response"],"acr":"aal2","mfa":true,"provider":"google","social_uid":"g-1001","kid":"key-ed25519-1"})).as_h)
      when "viewer-mfa-verified"
        MockClaims.new(JSON.parse(%({"sub":"u-viewer-1","cid":"cli-1","role":"viewer","scope":"data:read","amr":["challenge_response"],"acr":"aal2","mfa":true})).as_h)
      when "store-down"
        raise Azu::Auth::VerificationUnavailable.new("Redis down")
      else
        nil
      end
    end
  end

  class MockOAuthProviderHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      body_str = context.request.body.try(&.gets_to_end) || ""
      context.response.headers["X-OAuth-Body"] = body_str unless body_str.empty?
      context.response.print("oauth:#{context.request.method}:#{context.request.path}")
    end
  end

  struct ScopedResourceEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    get "/scoped-data"
    require_role :viewer
    require_scopes "data:read"

    def call : TextOut
      cid = claims["cid"]?.try(&.as_s?) || "none"
      TextOut.new("user=#{principal!.id},client=#{cid},has_read=#{scope?("data:read")}")
    end
  end

  struct ChallengeMfaTransferEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    post "/transfers"
    require_role :operator
    require_scopes "transfers:write"
    require_challenge_response!

    def call : TextOut
      TextOut.new(
        "transfer:user=#{principal!.id}:mfa=#{mfa_verified?}:challenge=#{challenge_authenticated?}:kid=#{principal!.as(Azu::Auth::Identity).key_id}"
      )
    end
  end

  struct AcrSensitiveVaultEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    get "/vault"
    require_role :operator
    require_mfa! :challenge_response, acr: "aal2"

    def call : TextOut
      TextOut.new("vault:acr=#{principal!.acr}:amr=#{principal!.amr.join("+")}")
    end
  end

  struct SocialProfileEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    get "/social/profile"
    require_role :viewer
    require_social! :google

    def call : TextOut
      ident = principal!.as(Azu::Auth::Identity)
      TextOut.new(
        "social:user=#{ident.id}:provider=#{auth_provider}:uid=#{ident.social_uid}:email=#{ident.email}:verified=#{ident.email_verified?}:social=#{social_authenticated?}"
      )
    end
  end

  struct ImperativeStepUpEndpoint
    include Azu::Endpoint(Azu::Request, TextOut)

    post "/billing/payout"
    require_role :operator

    def call : TextOut
      if header["X-High-Value"]? == "true"
        authorize!(challenge_response: true)
      end
      TextOut.new("payout:ok:mfa=#{mfa_verified?}")
    end
  end
end

private def call_dsl_app(
  app : Azu::App,
  method : String,
  path : String,
  headers : HTTP::Headers = HTTP::Headers.new,
  body : String? = nil,
) : {Int32, HTTP::Headers, String}
  chain = HTTP::Server.build_middleware([Azu::App::Scope.new(app)] of HTTP::Handler + app.default_handlers, ->(ctx : HTTP::Server::Context) { app.router.process(ctx); nil })
  req = HTTP::Request.new(method, path, headers: headers, body: body)
  io = IO::Memory.new
  res = HTTP::Server::Response.new(io)
  ctx = HTTP::Server::Context.new(req, res)
  chain.call(ctx)
  res.close
  io.rewind
  raw = io.gets_to_end
  resp_body = raw.split("\r\n\r\n", 2)[1]? || ""
  {res.status_code, res.headers, resp_body}
end

describe "Azu::Endpoint DSL, Action Hooks, and Conventions" do
  describe "conventional action naming" do
    it "derives dot-separated action names from endpoint type names" do
      Azu::Endpoint.derive_action_name("Api::Queues::PurgeEndpoint").should eq "queues.purge"
      Azu::Endpoint.derive_action_name("Endpoints::Admin::Users::ResetMfaEndpoint").should eq "admin.users.reset_mfa"
      Azu::Endpoint.derive_action_name("SignInEndpoint").should eq "sign_in"
      Azu::Endpoint.derive_action_name("HealthHandler").should eq "health"
      EndpointDslSpecFixtures::Api::Queues::PurgeEndpoint.conventional_action_name.should eq "endpoint_dsl_spec_fixtures.api.queues.purge"
    end
  end

  describe "declarative endpoint DSL and DI instance registration (router.endpoint)" do
    it "applies role, permission, policy module, hygiene, and audit! declarations from the endpoint" do
      viewer = Azu::Auth::Identity.new("v1", roles: ["viewer"])
      operator_no_perm = Azu::Auth::Identity.new("op1", roles: ["operator"])
      operator_with_perm = Azu::Auth::Identity.new("op2", roles: ["operator"], permissions: ["queues:purge"])
      pending_viewer = Azu::Auth::Identity.new("v-pend", roles: ["viewer"], enrolment_pending: true)

      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.router.method_not_allowed = true
      app.config.auth.enabled = true
      app.config.auth.roles = [:viewer, :operator, :admin]
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({
        "viewer"  => viewer,
        "op1"     => operator_no_perm,
        "op2"     => operator_with_perm,
        "pending" => pending_viewer,
      })

      audit_events = [] of Azu::Instrumentation::AuditEvent
      app.config.on_audit { |event| audit_events << event }

      queues = ["default", "critical"]

      app.routes do
        endpoint EndpointDslSpecFixtures::PublicHealthEndpoint
        endpoint EndpointDslSpecFixtures::EnrolmentStepEndpoint
        scope "/api", role: :viewer do
          endpoint EndpointDslSpecFixtures::Api::Queues::ListEndpoint.new(queues)
          endpoint EndpointDslSpecFixtures::Api::Queues::PurgeEndpoint.new(queues)
        end
      end

      # 1. Public endpoint skips auth and disables audit via no_audit!
      s_health, _, b_health = call_dsl_app(app, "GET", "/healthz")
      s_health.should eq 200
      b_health.should eq "ok"
      audit_events.should be_empty

      # 2. ListEndpoint inherits `role: :viewer` from enclosing `scope "/api", role: :viewer`
      s_list_unauth, _, _ = call_dsl_app(app, "GET", "/api/queues")
      s_list_unauth.should eq 401

      s_list_ok, _, b_list = call_dsl_app(app, "GET", "/api/queues", HTTP::Headers{"Authorization" => "Bearer viewer"})
      s_list_ok.should eq 200
      b_list.should eq "default,critical"

      # 3. PurgeEndpoint combines OperatorPolicy (`require_role :operator`, `audit! critical: true`, `before_action :verify_not_frozen`)
      #    and `require_permissions "queues:purge"`
      s_purge_viewer, _, _ = call_dsl_app(app, "POST", "/api/queues/default/purge", HTTP::Headers{"Authorization" => "Bearer viewer", "Content-Type" => "application/json"}, "{}")
      s_purge_viewer.should eq 403

      s_purge_op1, _, _ = call_dsl_app(app, "POST", "/api/queues/default/purge", HTTP::Headers{"Authorization" => "Bearer op1", "Content-Type" => "application/json"}, "{}")
      s_purge_op1.should eq 403

      # Hygiene: wrong Content-Type -> 415
      s_purge_415, _, _ = call_dsl_app(app, "POST", "/api/queues/default/purge", HTTP::Headers{"Authorization" => "Bearer op2", "Content-Type" => "text/plain"}, "hello")
      s_purge_415.should eq 415

      # Hygiene: oversized body (> 1024 bytes) -> 413
      s_purge_413, _, _ = call_dsl_app(app, "POST", "/api/queues/default/purge", HTTP::Headers{"Authorization" => "Bearer op2", "Content-Type" => "application/json"}, "x" * 1100)
      s_purge_413.should eq 413

      # Policy before_action hook: X-Queue-Frozen -> 409 Conflict
      s_frozen, _, b_frozen = call_dsl_app(
        app,
        "POST",
        "/api/queues/default/purge",
        HTTP::Headers{"Authorization" => "Bearer op2", "Content-Type" => "application/json", "X-Queue-Frozen" => "true"},
        "{}"
      )
      s_frozen.should eq 409
      JSON.parse(b_frozen)["error"]["code"].should eq "queue_frozen"

      # In-action `not_found!` helper when queue does not exist -> 404
      s_missing, _, b_missing = call_dsl_app(
        app,
        "POST",
        "/api/queues/unknown/purge",
        HTTP::Headers{"Authorization" => "Bearer op2", "Content-Type" => "application/json"},
        "{}"
      )
      s_missing.should eq 404
      JSON.parse(b_missing)["error"]["code"].should eq "queue_not_found"

      # Valid purge succeeds and records critical audit event with conventional action name
      audit_events.clear
      s_ok, _, b_ok = call_dsl_app(
        app,
        "POST",
        "/api/queues/default/purge",
        HTTP::Headers{"Authorization" => "Bearer op2", "Content-Type" => "application/json"},
        "{}"
      )
      s_ok.should eq 200
      b_ok.should eq "purged:default:by:op2"
      audit_events.map(&.outcome).should eq [
        Azu::Instrumentation::AuditOutcome::Pending,
        Azu::Instrumentation::AuditOutcome::Succeeded,
      ]
      audit_events.last.action.should eq EndpointDslSpecFixtures::Api::Queues::PurgeEndpoint.conventional_action_name

      # 4. EnrolmentStepEndpoint is enrolment_exempt! and csrf_exempt!
      s_enrol, _, b_enrol = call_dsl_app(app, "POST", "/enrolment/mfa", HTTP::Headers{"Authorization" => "Bearer pending"})
      s_enrol.should eq 200
      b_enrol.should eq "enrolled:v-pend"
    end

    it "supports inline per-verb options on multi-route endpoints and 3-layer RouteOptions merging" do
      app = Azu::App.new
      app.routes do
        endpoint EndpointDslSpecFixtures::MultiRouteEndpoint
      end

      table = app.router.route_table
      get_entry = table.find! { |entry| entry.method.get? && entry.pattern == "/multi-items" }
      post_entry = table.find! { |entry| entry.method.post? && entry.pattern == "/multi-items" }

      get_entry.requires.try(&.role).should eq "viewer"
      get_entry.summary.should eq "List multi items"

      post_entry.requires.try(&.role).should eq "operator"
      post_entry.requires.try(&.all_permissions).should eq ["items:write"]
      post_entry.summary.should eq "Create multi item"
    end
  end

  describe "before_action, after_action, around_action, halt!, and error helpers" do
    it "executes around_action, before_action, call, and after_action in exact order" do
      log = [] of String
      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.router.endpoint EndpointDslSpecFixtures::LifecycleHooksEndpoint.new(log)

      status, headers, body = call_dsl_app(app, "POST", "/hooks-demo")
      status.should eq 200
      body.should eq "done"
      headers["X-After-Result"]?.should eq "done"
      log.should eq [
        "around_outer:before",
        "around_inner:before",
        "before:one",
        "before:two",
        "call",
        "after:result=done",
        "after:final",
        "around_inner:after",
        "around_outer:after",
      ]
    end

    it "supports halt! to short-circuit execution with custom status, body, and headers" do
      log = [] of String
      app = Azu::App.new
      app.router.endpoint EndpointDslSpecFixtures::LifecycleHooksEndpoint.new(log)

      status, headers, body = call_dsl_app(app, "POST", "/hooks-demo", HTTP::Headers{"X-Halt" => "true"})
      status.should eq 202
      body.should eq "halted-early"
      headers["X-Halted"]?.should eq "yes"
      log.should eq [
        "around_outer:before",
        "around_inner:before",
        "before:one",
      ]
    end

    it "supports bad_request!, unprocessable!, and imperative authorize! inside action hooks" do
      log = [] of String
      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.router.endpoint EndpointDslSpecFixtures::LifecycleHooksEndpoint.new(log)

      s_bad, _, b_bad = call_dsl_app(app, "POST", "/hooks-demo", HTTP::Headers{"X-Bad" => "true"})
      s_bad.should eq 400
      JSON.parse(b_bad)["error"]["code"].should eq "bad_header"

      s_422, _, b_422 = call_dsl_app(app, "POST", "/hooks-demo", HTTP::Headers{"X-Invalid-Field" => "true"})
      s_422.should eq 422
      JSON.parse(b_422)["error"]["details"]["limit"].should eq ["must be positive"]

      # Imperative `authorize!` when no principal is present -> 401
      s_401, _, b_401 = call_dsl_app(app, "POST", "/hooks-demo", HTTP::Headers{"X-Require-Perm" => "secret:op"})
      s_401.should eq 401
      JSON.parse(b_401)["error"]["code"].should eq "unauthorized"
    end
  end

  describe "endpoint class inheritance" do
    it "inherits route_options and before_action hooks from a base endpoint class without sibling leakage" do
      sub_opts = EndpointDslSpecFixtures::SubAdminAuditEndpoint.route_options
      sub_opts.requires.try(&.role).should eq "admin"
      sub_opts.requires.try(&.all_permissions).should eq ["admin:audit"]

      sibling_opts = EndpointDslSpecFixtures::SiblingAdminEndpoint.route_options
      sibling_opts.requires.try(&.role).should eq "admin"
      sibling_opts.requires.try(&.all_permissions).should eq([] of String)

      app = Azu::App.new
      app.routes do
        endpoint EndpointDslSpecFixtures::SubAdminAuditEndpoint
        endpoint EndpointDslSpecFixtures::SiblingAdminEndpoint
      end

      s1, h1, b1 = call_dsl_app(app, "GET", "/admin/sub-audit")
      s1.should eq 200
      b1.should eq "sub"
      h1["X-Base-Hook"]?.should eq "ran"
      h1["X-Sub-Hook"]?.should eq "ran"

      s2, h2, b2 = call_dsl_app(app, "GET", "/admin/sibling")
      s2.should eq 200
      b2.should eq "base"
      h2["X-Base-Hook"]?.should eq "ran"
      h2["X-Sub-Hook"]?.should be_nil
    end
  end

  describe "conventional auth setup (c.api_defaults!, c.auth.jwt, c.auth.role_hierarchy, c.auth.authly, mount_authly)" do
    it "configures strict JSON API defaults and role_hierarchy by convention" do
      app = Azu::App.new
      app.config.api_defaults!
      app.config.auth.role_hierarchy :viewer, :operator, :admin

      app.config.error_format.should eq Azu::ErrorFormat::Envelope
      app.config.router.method_not_allowed?.should be_true
      app.config.router.method_override?.should be_false
      app.config.hygiene.strict_content_type?.should be_true
      app.config.hygiene.require_json_object?.should be_true
      app.config.hygiene.strict_request_id?.should be_true

      app.config.auth.roles.should eq ["viewer", "operator", "admin"]
      app.config.auth.default_access_for(Azu::Method::Get).try(&.role).should eq "viewer"
      app.config.auth.default_access_for(Azu::Method::Post).try(&.role).should eq "operator"
    end

    it "verifies HMAC JWT tokens, claims, scopes, and revocation blocks via c.auth.jwt" do
      secret = "test-jwt-hmac-secret-key-32-bytes!"
      revoked_jti = Set{"revoked-1"}

      app = Azu::App.new
      app.config.api_defaults!
      app.config.auth.jwt(secret, issuer: "https://auth.example.com", audience: "https://api.example.com") do |identity, _ctx|
        !revoked_jti.includes?(identity.token_id || "")
      end
      app.config.auth.role_hierarchy :viewer, :operator, :admin

      app.config.auth.enabled?.should be_true
      app.config.auth.bearer_format.should eq "JWT"

      app.routes do
        get "/items", EndpointDslSpecFixtures::PublicHealthEndpoint, role: :viewer, public: false
        post "/items", EndpointDslSpecFixtures::PublicHealthEndpoint,
          requires: Azu::Access.role(:operator) & Azu::Access.scopes("items:write"),
          public: false
      end

      now = Time.utc.to_unix
      make_jwt = ->(payload : Hash(String, JSON::Any::Type), alg : String, key : String) do
        hdr = Base64.urlsafe_encode({"alg" => alg, "typ" => "JWT"}.to_json, padding: false)
        pld = Base64.urlsafe_encode(payload.to_json, padding: false)
        sig = Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, key, "#{hdr}.#{pld}"), padding: false)
        "#{hdr}.#{pld}.#{sig}"
      end

      valid_token = make_jwt.call(
        {
          "sub"   => "u-42",
          "iss"   => "https://auth.example.com",
          "aud"   => "https://api.example.com",
          "exp"   => now + 300,
          "role"  => "operator",
          "scope" => "items:read items:write",
          "jti"   => "ok-1",
        } of String => JSON::Any::Type,
        "HS256",
        secret
      )

      s_ok, _, _ = call_dsl_app(
        app,
        "POST",
        "/items",
        HTTP::Headers{"Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json"},
        "{}"
      )
      s_ok.should eq 200

      # Expired token -> 401 token_expired
      expired_token = make_jwt.call(
        {
          "sub"  => "u-42",
          "iss"  => "https://auth.example.com",
          "aud"  => "https://api.example.com",
          "exp"  => now - 60,
          "role" => "operator",
        } of String => JSON::Any::Type,
        "HS256",
        secret
      )
      s_exp, _, b_exp = call_dsl_app(app, "GET", "/items", HTTP::Headers{"Authorization" => "Bearer #{expired_token}"})
      s_exp.should eq 401
      JSON.parse(b_exp)["error"]["code"].should eq "token_expired"

      # Revoked JTI -> 401 invalid_token
      revoked_token = make_jwt.call(
        {
          "sub"  => "u-42",
          "iss"  => "https://auth.example.com",
          "aud"  => "https://api.example.com",
          "exp"  => now + 300,
          "role" => "viewer",
          "jti"  => "revoked-1",
        } of String => JSON::Any::Type,
        "HS256",
        secret
      )
      s_rev, _, b_rev = call_dsl_app(app, "GET", "/items", HTTP::Headers{"Authorization" => "Bearer #{revoked_token}"})
      s_rev.should eq 401
      JSON.parse(b_rev)["error"]["code"].should eq "invalid_token"
    end

    it "integrates with Authly TokenVerifier via c.auth.authly, handles 503 store outages, and mounts OAuth2/OIDC routes via mount_authly" do
      verifier = EndpointDslSpecFixtures::MockAuthlyVerifier.new
      oauth_handler = EndpointDslSpecFixtures::MockOAuthProviderHandler.new

      app = Azu::App.new
      app.config.api_defaults!
      app.config.auth.authly(verifier, realm: "api")
      app.config.auth.role_hierarchy :viewer, :operator

      app.routes do
        mount_authly oauth_handler
        endpoint EndpointDslSpecFixtures::ScopedResourceEndpoint
      end

      # 1. Mounted OAuth2 / OIDC provider endpoints are public and csrf_exempt on token/discovery routes
      s_disc, _, b_disc = call_dsl_app(app, "GET", "/.well-known/openid-configuration")
      s_disc.should eq 200
      b_disc.should eq "oauth:GET:/.well-known/openid-configuration"

      s_tok, _, b_tok = call_dsl_app(app, "POST", "/oauth/token", HTTP::Headers{"Content-Type" => "application/json"}, "{}")
      s_tok.should eq 200
      b_tok.should eq "oauth:POST:/oauth/token"

      # 2. Protected resource endpoint checks OAuth2 scopes declared via require_scopes
      s_200, _, b_200 = call_dsl_app(app, "GET", "/scoped-data", HTTP::Headers{"Authorization" => "Bearer valid-scoped"})
      s_200.should eq 200
      b_200.should eq "user=u-99,client=cli-1,has_read=true"

      # Missing required scope -> 403 forbidden
      s_403, _, _ = call_dsl_app(app, "GET", "/scoped-data", HTTP::Headers{"Authorization" => "Bearer missing-scope"})
      s_403.should eq 403

      # 3. Token store outage raises VerificationUnavailable -> 503 with Retry-After: 1 and Cache-Control: no-store
      s_503, h_503, b_503 = call_dsl_app(app, "GET", "/scoped-data", HTTP::Headers{"Authorization" => "Bearer store-down"})
      s_503.should eq 503
      h_503["Retry-After"]?.should eq "1"
      h_503["Cache-Control"]?.should eq "no-store"
      JSON.parse(b_503)["error"]["code"].should eq "temporarily_unavailable"
    end

    it "supports Authly MFA challenge-response routes, form-urlencoded OAuth hygiene, and declarative/imperative MFA enforcement" do
      verifier = EndpointDslSpecFixtures::MockAuthlyVerifier.new
      oauth_handler = EndpointDslSpecFixtures::MockOAuthProviderHandler.new

      app = Azu::App.new
      app.config.api_defaults!
      app.config.auth.authly(verifier, realm: "api")
      app.config.auth.role_hierarchy :viewer, :operator, :admin

      app.routes do
        mount_authly oauth_handler
        endpoint EndpointDslSpecFixtures::ChallengeMfaTransferEndpoint
        endpoint EndpointDslSpecFixtures::AcrSensitiveVaultEndpoint
        endpoint EndpointDslSpecFixtures::ImperativeStepUpEndpoint
      end

      # 1. POST /oauth/challenge accepts both JSON and application/x-www-form-urlencoded even under c.api_defaults!
      s_chal_json, h_chal_json, b_chal_json = call_dsl_app(
        app,
        "POST",
        "/oauth/challenge",
        HTTP::Headers{"Content-Type" => "application/json"},
        %({"client_id":"cli-1","subject":"u-social-1","key_id":"key-ed25519-1"})
      )
      s_chal_json.should eq 200
      b_chal_json.should eq "oauth:POST:/oauth/challenge"
      h_chal_json["X-OAuth-Body"]?.should eq %({"client_id":"cli-1","subject":"u-social-1","key_id":"key-ed25519-1"})

      s_chal_form, h_chal_form, b_chal_form = call_dsl_app(
        app,
        "POST",
        "/oauth/challenge",
        HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        "client_id=cli-1&subject=u-social-1&key_id=key-ed25519-1"
      )
      s_chal_form.should eq 200
      b_chal_form.should eq "oauth:POST:/oauth/challenge"
      h_chal_form["X-OAuth-Body"]?.should eq "client_id=cli-1&subject=u-social-1&key_id=key-ed25519-1"

      # 2. POST /oauth/token with grant_type=challenge_response (form-urlencoded) passes hygiene & CSRF checks
      s_tok_cr, h_tok_cr, b_tok_cr = call_dsl_app(
        app,
        "POST",
        "/oauth/token",
        HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        "grant_type=challenge_response&client_id=cli-1&challenge_id=ch-1&signature=deadbeef"
      )
      s_tok_cr.should eq 200
      b_tok_cr.should eq "oauth:POST:/oauth/token"
      h_tok_cr["X-OAuth-Body"]?.should eq "grant_type=challenge_response&client_id=cli-1&challenge_id=ch-1&signature=deadbeef"

      # 3. Declarative require_challenge_response! rejects single-factor token with 403 mfa_required + WWW-Authenticate
      s_no_mfa, h_no_mfa, b_no_mfa = call_dsl_app(
        app,
        "POST",
        "/transfers",
        HTTP::Headers{"Authorization" => "Bearer social-google-factor1", "Content-Type" => "application/json"},
        "{}"
      )
      s_no_mfa.should eq 403
      JSON.parse(b_no_mfa)["error"]["code"].should eq "mfa_required"
      (h_no_mfa["WWW-Authenticate"]? || "").should contain("insufficient_user_authentication")

      # 4. Role failure takes precedence over MFA failure (viewer has MFA, but /transfers requires :operator)
      s_role_fail, _, b_role_fail = call_dsl_app(
        app,
        "POST",
        "/transfers",
        HTTP::Headers{"Authorization" => "Bearer viewer-mfa-verified", "Content-Type" => "application/json"},
        "{}"
      )
      s_role_fail.should eq 403
      JSON.parse(b_role_fail)["error"]["code"].should eq "forbidden"

      # 5. Challenge-response MFA token succeeds on both ChallengeMfaTransferEndpoint and AcrSensitiveVaultEndpoint
      s_mfa_ok, _, b_mfa_ok = call_dsl_app(
        app,
        "POST",
        "/transfers",
        HTTP::Headers{"Authorization" => "Bearer mfa-challenge-verified", "Content-Type" => "application/json"},
        "{}"
      )
      s_mfa_ok.should eq 200
      b_mfa_ok.should eq "transfer:user=u-social-1:mfa=true:challenge=true:kid=key-ed25519-1"

      s_vault_ok, _, b_vault_ok = call_dsl_app(
        app,
        "GET",
        "/vault",
        HTTP::Headers{"Authorization" => "Bearer mfa-challenge-verified"}
      )
      s_vault_ok.should eq 200
      b_vault_ok.should eq "vault:acr=aal2:amr=social+challenge_response"

      # 6. Imperative step-up MFA via authorize!(challenge_response: true)
      s_low_val, _, b_low_val = call_dsl_app(
        app,
        "POST",
        "/billing/payout",
        HTTP::Headers{"Authorization" => "Bearer social-google-factor1", "Content-Type" => "application/json"},
        "{}"
      )
      s_low_val.should eq 200
      b_low_val.should eq "payout:ok:mfa=false"

      s_high_no_mfa, h_high_no_mfa, b_high_no_mfa = call_dsl_app(
        app,
        "POST",
        "/billing/payout",
        HTTP::Headers{"Authorization" => "Bearer social-google-factor1", "Content-Type" => "application/json", "X-High-Value" => "true"},
        "{}"
      )
      s_high_no_mfa.should eq 403
      JSON.parse(b_high_no_mfa)["error"]["code"].should eq "mfa_required"
      (h_high_no_mfa["WWW-Authenticate"]? || "").should contain("insufficient_user_authentication")

      s_high_mfa, _, b_high_mfa = call_dsl_app(
        app,
        "POST",
        "/billing/payout",
        HTTP::Headers{"Authorization" => "Bearer mfa-challenge-verified", "Content-Type" => "application/json", "X-High-Value" => "true"},
        "{}"
      )
      s_high_mfa.should eq 200
      b_high_mfa.should eq "payout:ok:mfa=true"
    end

    it "supports Authly Social Login routes (GET/POST callback, grant_type=social), scoped mount_authly prefix stripping, and social identity claims" do
      verifier = EndpointDslSpecFixtures::MockAuthlyVerifier.new
      oauth_handler = EndpointDslSpecFixtures::MockOAuthProviderHandler.new

      app = Azu::App.new
      app.config.api_defaults!
      app.config.csrf_guard.enabled = true
      app.config.auth.authly(verifier, realm: "api")
      app.config.auth.role_hierarchy :viewer, :operator, :admin

      app.routes do
        mount_authly oauth_handler
        scope "/auth" do
          mount_authly oauth_handler
        end
        endpoint EndpointDslSpecFixtures::SocialProfileEndpoint
      end

      # 1. GET /oauth/social/:provider initiates redirect flow
      s_soc_init, _, b_soc_init = call_dsl_app(app, "GET", "/oauth/social/google")
      s_soc_init.should eq 200
      b_soc_init.should eq "oauth:GET:/oauth/social/google"

      # 2. GET /oauth/social/:provider/callback and cross-origin POST /oauth/social/:provider/callback (Apple form_post)
      #    work even when CSRF guard and strict JSON hygiene are enabled
      s_soc_cb_get, _, b_soc_cb_get = call_dsl_app(app, "GET", "/oauth/social/google/callback?code=abc&state=xyz")
      s_soc_cb_get.should eq 200
      b_soc_cb_get.should eq "oauth:GET:/oauth/social/google/callback"

      s_soc_cb_post, h_soc_cb_post, b_soc_cb_post = call_dsl_app(
        app,
        "POST",
        "/oauth/social/apple/callback",
        HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Origin" => "https://appleid.apple.com"},
        "code=apple-code&state=apple-state"
      )
      s_soc_cb_post.should eq 200
      b_soc_cb_post.should eq "oauth:POST:/oauth/social/apple/callback"
      h_soc_cb_post["X-OAuth-Body"]?.should eq "code=apple-code&state=apple-state"

      # 3. POST /oauth/token with grant_type=social exchanges social assertion for Authly token
      s_soc_tok, h_soc_tok, b_soc_tok = call_dsl_app(
        app,
        "POST",
        "/oauth/token",
        HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        "grant_type=social&provider=google&subject=g-1001&code_verifier=pkce-verifier"
      )
      s_soc_tok.should eq 200
      b_soc_tok.should eq "oauth:POST:/oauth/token"
      h_soc_tok["X-OAuth-Body"]?.should eq "grant_type=social&provider=google&subject=g-1001&code_verifier=pkce-verifier"

      # 4. Scoped mount_authly (`scope "/auth" { mount_authly }`) strips "/auth" prefix for Authly::Handler
      s_scoped_chal, h_scoped_chal, b_scoped_chal = call_dsl_app(
        app,
        "POST",
        "/auth/oauth/challenge",
        HTTP::Headers{"Content-Type" => "application/json"},
        %({"client_id":"cli-1"})
      )
      s_scoped_chal.should eq 200
      b_scoped_chal.should eq "oauth:POST:/oauth/challenge"
      h_scoped_chal["X-OAuth-Body"]?.should eq %({"client_id":"cli-1"})

      s_scoped_soc, _, b_scoped_soc = call_dsl_app(app, "GET", "/auth/oauth/social/github")
      s_scoped_soc.should eq 200
      b_scoped_soc.should eq "oauth:GET:/oauth/social/github"

      # 5. SocialProfileEndpoint (`require_social! :google`) extracts social claims and enforces provider constraint
      s_google, _, b_google = call_dsl_app(
        app,
        "GET",
        "/social/profile",
        HTTP::Headers{"Authorization" => "Bearer social-google-factor1"}
      )
      s_google.should eq 200
      b_google.should eq "social:user=u-social-1:provider=google:uid=g-1001:email=dev@example.com:verified=true:social=true"

      # GitHub social token is rejected on a `:google`-restricted endpoint with 403 forbidden
      s_github, _, b_github = call_dsl_app(
        app,
        "GET",
        "/social/profile",
        HTTP::Headers{"Authorization" => "Bearer social-github-factor1"}
      )
      s_github.should eq 403
      JSON.parse(b_github)["error"]["code"].should eq "forbidden"

      # 6. OpenAPI generation includes x-required-mfa, x-required-amr, x-required-acr, and x-required-social-providers
      app.router.endpoint EndpointDslSpecFixtures::ChallengeMfaTransferEndpoint
      app.router.endpoint EndpointDslSpecFixtures::AcrSensitiveVaultEndpoint
      openapi = JSON.parse(Azu::OpenAPI.document(app, Azu::OpenAPI::Info.new(title: "Test", version: "1.0")).to_json)
      paths = openapi["paths"]
      transfer_op = paths["/transfers"]["post"]
      transfer_op["x-required-mfa"].as_bool.should be_true
      transfer_op["x-required-amr"].as_a.map(&.as_s).should eq ["challenge_response", "urn:ietf:params:oauth:grant-type:challenge"]

      vault_op = paths["/vault"]["get"]
      vault_op["x-required-mfa"].as_bool.should be_true
      vault_op["x-required-acr"].as_s.should eq "aal2"

      social_op = paths["/social/profile"]["get"]
      social_op["x-required-social"].as_bool.should be_true
      social_op["x-required-social-providers"].as_a.map(&.as_s).should eq ["google"]
    end
  end
end
