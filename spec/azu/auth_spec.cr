require "../spec_helper"

private struct AuthSpecPayloadRequest
  include Azu::Request

  getter name : String
  getter count : Int32 = 1

  def initialize(@name = "", @count = 1)
  end

  validate :name, presence: true, message: "Name cannot be blank"
end

private struct AuthSpecResponse
  include Azu::Response

  def initialize(@body : String)
  end

  def render
    @body
  end
end

private struct AuthSpecGetEndpoint
  include Azu::Endpoint(Azu::Request, AuthSpecResponse)

  def initialize(@label : String = "ok")
  end

  def call : AuthSpecResponse
    principal_id = context.principal.try(&.id) || "anonymous"
    AuthSpecResponse.new("#{@label}:#{principal_id}")
  end
end

private struct AuthSpecCreateEndpoint
  include Azu::Endpoint(AuthSpecPayloadRequest, AuthSpecResponse)

  def call : AuthSpecResponse
    AuthSpecResponse.new("created:#{auth_spec_payload_request.name}:#{context.principal!.id}")
  end
end

private def build_auth_ctx(
  method : String,
  path : String,
  headers : HTTP::Headers = HTTP::Headers.new,
  body : String? = nil,
) : HTTP::Server::Context
  request = HTTP::Request.new(method, path, headers, body)
  response = HTTP::Server::Response.new(IO::Memory.new)
  HTTP::Server::Context.new(request, response)
end

private def call_app(
  app : Azu::App,
  handlers : Array(HTTP::Handler),
  method : String,
  path : String,
  headers : HTTP::Headers = HTTP::Headers.new,
  body : String? = nil,
) : {Int32, HTTP::Headers, String}
  dispatcher = app.dispatcher(handlers)
  request = HTTP::Request.new(method, path, headers, body)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  dispatcher.call(context)
  response.close
  raw = io.to_s
  payload = raw.includes?("\r\n\r\n") ? raw.split("\r\n\r\n", 2).last : raw
  {response.status_code, response.headers, payload}
end

describe Azu::Auth do
  describe "BearerAuthenticator and ChainAuthenticator" do
    it "authenticates static bearer tokens in constant time and rejects invalid or non-bearer headers" do
      viewer = Azu::Auth::Identity.new("u-viewer", roles: ["viewer"])
      admin = Azu::Auth::Identity.new("u-admin", roles: ["admin"])
      auth = Azu::Auth::BearerAuthenticator.new({
        "tok_viewer_secret" => viewer,
        "tok_admin_secret"  => admin,
      })

      ctx_ok = build_auth_ctx("GET", "/queues", HTTP::Headers{"Authorization" => "Bearer tok_viewer_secret"})
      auth.authenticate(ctx_ok).should eq viewer

      ctx_case = build_auth_ctx("GET", "/queues", HTTP::Headers{"Authorization" => "bearer   tok_admin_secret  "})
      auth.authenticate(ctx_case).should eq admin

      ctx_bad = build_auth_ctx("GET", "/queues", HTTP::Headers{"Authorization" => "Bearer wrong"})
      auth.authenticate(ctx_bad).should be_nil

      ctx_basic = build_auth_ctx("GET", "/queues", HTTP::Headers{"Authorization" => "Basic dXNlcjpwYXNz"})
      auth.authenticate(ctx_basic).should be_nil

      ctx_none = build_auth_ctx("GET", "/queues")
      auth.authenticate(ctx_none).should be_nil
    end

    it "supports lookup blocks and chaining authenticators" do
      bearer = Azu::Auth::BearerAuthenticator.new do |token, _ctx|
        Azu::Auth::Identity.new("bearer:#{token}", roles: ["operator"]) if token == "valid-token"
      end
      api_key = Azu::Auth::ProcAuthenticator.new do |ctx|
        if key = ctx.request.headers["X-API-Key"]?
          Azu::Auth::Identity.new("key:#{key}", roles: ["viewer"], auth_scheme: :api_key) if key == "k1"
        end
      end
      chain = Azu::Auth::ChainAuthenticator.new([bearer, api_key] of Azu::Auth::Authenticator)

      ctx1 = build_auth_ctx("GET", "/queues", HTTP::Headers{"Authorization" => "Bearer valid-token"})
      chain.authenticate(ctx1).try(&.id).should eq "bearer:valid-token"

      ctx2 = build_auth_ctx("GET", "/queues", HTTP::Headers{"X-API-Key" => "k1"})
      chain.authenticate(ctx2).try(&.id).should eq "key:k1"
    end
  end

  describe "401 before routing, public routes, and revocation check" do
    it "answers 401 before routing so unauthenticated callers cannot probe whether a route or method exists" do
      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.router.method_not_allowed = true
      app.config.auth.enabled = true
      app.config.auth.roles = [:viewer, :operator, :admin]
      app.config.auth.default_read_role = :viewer
      app.config.auth.default_write_role = :operator
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({
        "viewer-tok" => Azu::Auth::Identity.new("u1", roles: ["viewer"]),
      })

      app.router.get "/queues", AuthSpecGetEndpoint.new("queues")
      app.router.post "/session", AuthSpecGetEndpoint.new("signed-in"), public: true

      handlers = [Azu::Handler::Rescuer.new, Azu::Handler::Authentication.new(app.config)] of HTTP::Handler

      # Unknown route without token -> 401 (not 404)
      status, res_headers, body = call_app(app, handlers, "GET", "/does-not-exist")
      status.should eq 401
      res_headers["WWW-Authenticate"]?.should eq "Bearer"
      JSON.parse(body)["error"]["code"].should eq "unauthorized"

      # Wrong method on existing route without token -> 401 (not 405)
      status405, _, _ = call_app(app, app.default_handlers, "DELETE", "/queues")
      status405.should eq 401

      # Public route without token -> 200
      pub_status, _, pub_body = call_app(app, app.default_handlers, "POST", "/session")
      pub_status.should eq 200
      pub_body.should eq "signed-in:anonymous"

      # Wrong method on public path (/session only has POST, not GET) without token -> 401
      wrong_pub_status, _, _ = call_app(app, app.default_handlers, "GET", "/session")
      wrong_pub_status.should eq 401
    end

    it "rejects revoked principals via Principal#valid?(context) with 401" do
      revoked = Atomic(Bool).new(false)
      principal = Azu::Auth::Identity.new(
        "u-revokable",
        roles: ["admin"],
        validator: ->(_ctx : HTTP::Server::Context) { !revoked.get }
      )

      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.auth.enabled = true
      app.config.auth.roles = [:admin]
      app.config.auth.default_read_role = :admin
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({"tok" => principal})
      app.router.get "/secret", AuthSpecGetEndpoint.new("secret")

      hdrs = HTTP::Headers{"Authorization" => "Bearer tok"}
      s1, _, b1 = call_app(app, app.default_handlers, "GET", "/secret", hdrs)
      s1.should eq 200
      b1.should eq "secret:u-revokable"

      revoked.set(true)
      s2, _, b2 = call_app(app, app.default_handlers, "GET", "/secret", hdrs)
      s2.should eq 401
      JSON.parse(b2)["error"]["code"].should eq "unauthorized"
    end
  end

  describe "ordered roles, permissions, verb defaults, and enrolment gate" do
    it "enforces ordered roles, permission sets, per-verb defaults, and enrolment gate" do
      viewer = Azu::Auth::Identity.new("viewer-1", roles: ["viewer"], permissions: ["queues:read"])
      operator = Azu::Auth::Identity.new("op-1", roles: ["operator"], permissions: ["queues:read", "queues:write"])
      operator_purge = Azu::Auth::Identity.new("op-purge", roles: ["operator"], permissions: ["queues:read", "queues:write", "queues:purge"])
      admin = Azu::Auth::Identity.new("admin-1", roles: ["admin"])
      un_enrolled = Azu::Auth::Identity.new("pending-1", roles: ["admin"], enrolment_pending: true)

      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.router.method_not_allowed = true
      app.config.auth.enabled = true
      app.config.auth.roles = [:viewer, :operator, :admin]
      app.config.auth.default_read_role = :viewer
      app.config.auth.default_write_role = :operator
      app.config.auth.enrolment_error_code = "mfa_enrolment_required"
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({
        "viewer"   => viewer,
        "operator" => operator,
        "purge"    => operator_purge,
        "admin"    => admin,
        "pending"  => un_enrolled,
      })

      # Uses default_read_role (:viewer)
      app.router.get "/queues", AuthSpecGetEndpoint.new("list")
      # Uses default_write_role (:operator)
      app.router.post "/queues", AuthSpecGetEndpoint.new("create")
      # Explicit composite requirement: role(:operator) & permissions("queues:purge")
      app.router.post "/queues/purge", AuthSpecGetEndpoint.new("purge"),
        requires: Azu::Access.role(:operator) & Azu::Access.permissions("queues:purge")
      # Enrolment-exempt route for completing MFA setup
      app.router.post "/enrolment/mfa", AuthSpecGetEndpoint.new("enrolled"),
        requires: Azu::Access.role(:viewer),
        enrolment_exempt: true

      # Viewer can GET /queues (200), but cannot POST /queues (403)
      s_get, _, _ = call_app(app, app.default_handlers, "GET", "/queues", HTTP::Headers{"Authorization" => "Bearer viewer"})
      s_get.should eq 200

      s_post, _, b_post = call_app(app, app.default_handlers, "POST", "/queues", HTTP::Headers{"Authorization" => "Bearer viewer"})
      s_post.should eq 403
      JSON.parse(b_post)["error"]["code"].should eq "forbidden"

      # Operator satisfies :viewer (ordered hierarchy) and :operator, but lacks "queues:purge"
      s_op_get, _, _ = call_app(app, app.default_handlers, "GET", "/queues", HTTP::Headers{"Authorization" => "Bearer operator"})
      s_op_get.should eq 200

      s_op_post, _, _ = call_app(app, app.default_handlers, "POST", "/queues", HTTP::Headers{"Authorization" => "Bearer operator"})
      s_op_post.should eq 200

      s_op_purge, _, _ = call_app(app, app.default_handlers, "POST", "/queues/purge", HTTP::Headers{"Authorization" => "Bearer operator"})
      s_op_purge.should eq 403

      # Operator with queues:purge permission succeeds on /queues/purge
      s_purge_ok, _, _ = call_app(app, app.default_handlers, "POST", "/queues/purge", HTTP::Headers{"Authorization" => "Bearer purge"})
      s_purge_ok.should eq 200

      # Pending enrolment account gets 403 with "mfa_enrolment_required" on normal routes, but 200 on enrolment_exempt route
      s_pend_blocked, _, b_pend = call_app(app, app.default_handlers, "GET", "/queues", HTTP::Headers{"Authorization" => "Bearer pending"})
      s_pend_blocked.should eq 403
      JSON.parse(b_pend)["error"]["code"].should eq "mfa_enrolment_required"

      s_pend_exempt, _, b_exempt = call_app(app, app.default_handlers, "POST", "/enrolment/mfa", HTTP::Headers{"Authorization" => "Bearer pending"})
      s_pend_exempt.should eq 200
      b_exempt.should eq "enrolled:pending-1"
    end
  end

  describe "boot validation rules (Configuration#check_auth_boot! and App#validate_pipeline!)" do
    it "fails at boot when route requires: is present without Auth::Authorize" do
      app = Azu::App.new
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({"t" => Azu::Auth::Identity.new("1", roles: ["admin"])})
      app.router.get "/admin", AuthSpecGetEndpoint.new, requires: Azu::Access.role(:admin)

      expect_raises(Azu::Configuration::BootError, /Authorize/) do
        app.config.check_auth_boot!([Azu::Handler::Authentication.new(app.config)] of HTTP::Handler)
      end
    end

    it "fails at boot when Auth::Authorize is registered without an authenticator or AuthenticationStage" do
      app = Azu::App.new
      app.router.before_dispatch(Azu::Auth::Authorize.new(app.config))
      app.router.get "/admin", AuthSpecGetEndpoint.new, requires: Azu::Access.role(:admin)

      expect_raises(Azu::Configuration::BootError, /authenticator|AuthenticationStage/) do
        app.config.check_auth_boot!([] of HTTP::Handler)
      end
    end

    it "fails at boot when a non-public route has no effective requirement while Authorize is active" do
      app = Azu::App.new
      app.config.auth.enabled = true
      app.config.auth.roles = [:viewer, :admin]
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({"t" => Azu::Auth::Identity.new("1", roles: ["admin"])})
      app.router.get "/covered", AuthSpecGetEndpoint.new, requires: Azu::Access.role(:viewer)
      app.router.get "/uncovered", AuthSpecGetEndpoint.new

      expect_raises(Azu::Configuration::BootError, /\/uncovered/) do
        app.validate_pipeline!(app.default_handlers)
      end
    end

    it "fails at boot when a route or default references a role not in c.auth.roles" do
      app = Azu::App.new
      app.config.auth.enabled = true
      app.config.auth.roles = [:viewer, :operator]
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({"t" => Azu::Auth::Identity.new("1", roles: ["viewer"])})
      app.router.get "/super", AuthSpecGetEndpoint.new, requires: Azu::Access.role(:superadmin)

      expect_raises(Azu::Configuration::BootError, /Unknown role "superadmin"/) do
        app.validate_pipeline!(app.default_handlers)
      end
    end
  end

  describe "pinned check-order contract (401 -> 404/405 -> 403 -> 413/415 -> 400/422 -> action)" do
    it "enforces the exact check order across pre-routing and post-routing stages" do
      viewer = Azu::Auth::Identity.new("v1", roles: ["viewer"])
      operator = Azu::Auth::Identity.new("o1", roles: ["operator"])

      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.validation_error_mode = Azu::ValidationErrorMode::FirstMessageOnly
      app.config.router.method_not_allowed = true
      app.config.auth.enabled = true
      app.config.auth.roles = [:viewer, :operator]
      app.config.auth.default_read_role = :viewer
      app.config.auth.default_write_role = :operator
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({
        "viewer"   => viewer,
        "operator" => operator,
      })
      app.config.hygiene.max_body_size = 64_u64
      app.config.hygiene.strict_content_type = true
      app.config.hygiene.allowed_content_types = ["application/json"]
      app.config.hygiene.require_json_object = true

      app.router.post "/items", AuthSpecCreateEndpoint.new

      # 1. 401 before 404/405/413/415: unauthenticated request to unknown route with bad Content-Type & huge body -> 401
      s401, _, _ = call_app(
        app,
        app.default_handlers,
        "DELETE",
        "/unknown",
        HTTP::Headers{"Content-Type" => "text/plain"},
        "x" * 200
      )
      s401.should eq 401

      # 2. 404 and 405 before 403/413/415: authenticated viewer (insufficient role for POST) with bad Content-Type & huge body
      viewer_bad_headers = HTTP::Headers{
        "Authorization" => "Bearer viewer",
        "Content-Type"  => "text/plain",
      }
      s404, _, _ = call_app(app, app.default_handlers, "POST", "/unknown", viewer_bad_headers, "x" * 200)
      s404.should eq 404

      s405, h405, _ = call_app(app, app.default_handlers, "DELETE", "/items", viewer_bad_headers, "x" * 200)
      s405.should eq 405
      h405["Allow"]?.should eq "POST"

      # 3. 403 before 413/415/422: authenticated viewer on matched POST /items with huge body and text/plain -> 403
      s403, _, _ = call_app(app, app.default_handlers, "POST", "/items", viewer_bad_headers, "x" * 200)
      s403.should eq 403

      # 4. 413 before 415/422: authorized operator on POST /items with oversized body -> 413
      op_bad_ct = HTTP::Headers{
        "Authorization" => "Bearer operator",
        "Content-Type"  => "text/plain",
      }
      s413, _, _ = call_app(app, app.default_handlers, "POST", "/items", op_bad_ct, "x" * 200)
      s413.should eq 413

      # 5. 415 before 400/422: authorized operator on POST /items within size limit but text/plain -> 415
      s415, h415, _ = call_app(app, app.default_handlers, "POST", "/items", op_bad_ct, "{bad")
      s415.should eq 415
      h415["Accept-Post"]?.should eq "application/json"

      # 6. 400 malformed JSON vs 422 non-object JSON vs 422 contract failure:
      op_json = HTTP::Headers{
        "Authorization" => "Bearer operator",
        "Content-Type"  => "application/json",
      }
      s400, _, b400 = call_app(app, app.default_handlers, "POST", "/items", op_json, "{bad json")
      s400.should eq 400
      JSON.parse(b400)["error"]["code"].should eq "invalid_json"

      s422_arr, _, b422_arr = call_app(app, app.default_handlers, "POST", "/items", op_json, "[1, 2, 3]")
      s422_arr.should eq 422
      JSON.parse(b422_arr)["error"]["message"].should eq "Request body must be a JSON object"

      s422_contract, _, b422_contract = call_app(app, app.default_handlers, "POST", "/items", op_json, %({"name":""}))
      s422_contract.should eq 422
      JSON.parse(b422_contract)["error"]["code"].should eq "validation_failed"
      JSON.parse(b422_contract)["error"]["message"].should eq "name: Name cannot be blank"

      # 7. Valid request reaches the action -> 200
      s200, _, b200 = call_app(app, app.default_handlers, "POST", "/items", op_json, %({"name":"widget"}))
      s200.should eq 200
      b200.should eq "created:widget:o1"
    end
  end
end
