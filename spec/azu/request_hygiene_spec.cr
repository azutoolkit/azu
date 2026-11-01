require "../spec_helper"

private struct HygienePayloadRequest
  include Azu::Request

  getter title : String = "default"
  getter priority : Int32 = 1

  def initialize(@title = "default", @priority = 1)
  end

  validate :title, presence: true, message: "Title cannot be blank"
end

private struct HygieneSpecResponse
  include Azu::Response

  def initialize(@body : String)
  end

  def render
    @body
  end
end

private struct HygieneActionEndpoint
  include Azu::Endpoint(HygienePayloadRequest, HygieneSpecResponse)

  def call : HygieneSpecResponse
    req = hygiene_payload_request
    HygieneSpecResponse.new("ok:#{req.title}:#{req.priority}")
  end
end

private struct HygieneSimpleEndpoint
  include Azu::Endpoint(Azu::Request, HygieneSpecResponse)

  getter calls : Array(Int32) = [] of Int32

  def call : HygieneSpecResponse
    @calls << (@calls.size + 1)
    HygieneSpecResponse.new("called:#{@calls.size}")
  end
end

private def invoke_app(
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

describe "Request hygiene, CSRF header guard, strict RequestId, and observability/audit hooks" do
  describe "413 body size, 415 content-type, and JSON-object check (400 vs 422)" do
    it "enforces body size limit (413), content-type (415), and JSON-object rules (400 vs 422)" do
      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.hygiene.max_body_size = 32_u64
      app.config.hygiene.strict_content_type = true
      app.config.hygiene.allowed_content_types = ["application/json"]
      app.config.hygiene.require_json_object = true

      app.router.post "/tasks", HygieneActionEndpoint.new, public: true

      # 1. Oversized body -> 413
      s413, _, b413 = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/tasks",
        HTTP::Headers{"Content-Type" => "application/json"},
        %({"title":"#{"a" * 50}"})
      )
      s413.should eq 413
      JSON.parse(b413)["error"]["code"].should eq "payload_too_large"

      # 2. Wrong Content-Type -> 415 with Accept and Accept-Post headers
      s415, h415, b415 = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/tasks",
        HTTP::Headers{"Content-Type" => "text/plain"},
        %({"title":"hi"})
      )
      s415.should eq 415
      h415["Accept"]?.should eq "application/json"
      h415["Accept-Post"]?.should eq "application/json"
      JSON.parse(b415)["error"]["code"].should eq "unsupported_media_type"

      # 3. Missing Content-Type when body is present -> 415
      s415_missing, _, _ = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/tasks",
        HTTP::Headers.new,
        %({"title":"hi"})
      )
      s415_missing.should eq 415

      # 4. Syntactically invalid JSON -> 400 invalid_json (by default)
      json_hdr = HTTP::Headers{"Content-Type" => "application/json; charset=utf-8"}
      s400, _, b400 = invoke_app(app, app.default_handlers, "POST", "/tasks", json_hdr, "{broken")
      s400.should eq 400
      JSON.parse(b400)["error"]["code"].should eq "invalid_json"
      JSON.parse(b400)["error"]["message"].should eq "Request body is not valid JSON"

      # 5. Configurable malformed_json_status = 422
      app.config.hygiene.malformed_json_status = HTTP::Status::UNPROCESSABLE_ENTITY
      s422_bad, _, b422_bad = invoke_app(app, app.default_handlers, "POST", "/tasks", json_hdr, "{broken")
      s422_bad.should eq 422
      JSON.parse(b422_bad)["error"]["code"].should eq "invalid_json"
      app.config.hygiene.malformed_json_status = HTTP::Status::BAD_REQUEST

      # 6. Valid non-object JSON ([], "str", 123, true) -> 422 validation_failed
      ["[1,2]", %("hello"), "123", "true"].each do |non_obj|
        status, _, body = invoke_app(app, app.default_handlers, "POST", "/tasks", json_hdr, non_obj)
        status.should eq 422
        err = JSON.parse(body)["error"]
        err["code"].should eq "validation_failed"
        err["message"].should eq "Request body must be a JSON object"
      end

      # 7. Empty body "" and "null" treated as "{}" -> uses contract defaults -> 200
      ["", "null"].each do |empty_like|
        status, _, body = invoke_app(app, app.default_handlers, "POST", "/tasks", json_hdr, empty_like)
        status.should eq 200
        body.should eq "ok:default:1"
      end

      # 8. Valid JSON object with wrong field type -> 422 validation_failed
      s_type, _, b_type = invoke_app(app, app.default_handlers, "POST", "/tasks", json_hdr, %({"priority":"nan"}))
      s_type.should eq 422
      JSON.parse(b_type)["error"]["code"].should eq "validation_failed"
    end
  end

  describe "CSRF header guard for cookie sessions and anonymous state-changing endpoints" do
    it "requires X-Requested-With on cookie/anonymous state-changing requests and exempts bearer tokens and csrf_exempt routes" do
      cookie_user = Azu::Auth::Identity.new("u-cookie", roles: ["operator"], auth_scheme: :cookie)
      bearer_user = Azu::Auth::Identity.new("u-bearer", roles: ["operator"], auth_scheme: :bearer)

      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.auth.enabled = true
      app.config.auth.roles = [:operator]
      app.config.auth.default_write_role = :operator
      app.config.auth.authenticator = Azu::Auth::ProcAuthenticator.new do |ctx|
        case ctx.request.headers["X-Test-Auth"]?
        when "cookie" then cookie_user
        when "bearer" then bearer_user
        else               nil
        end
      end
      app.config.csrf_guard.enabled = true
      app.config.csrf_guard.header_name = "X-Requested-With"

      app.router.post "/session", HygieneSimpleEndpoint.new, public: true
      app.router.post "/queues", HygieneSimpleEndpoint.new
      app.router.post "/webhooks", HygieneSimpleEndpoint.new, public: true, csrf_exempt: true

      # 1. Anonymous POST /session (public) without X-Requested-With -> 403 code: "csrf"
      s1, _, b1 = invoke_app(app, app.default_handlers, "POST", "/session")
      s1.should eq 403
      JSON.parse(b1)["error"]["code"].should eq "csrf"

      # 2. Anonymous POST /session with X-Requested-With -> 200
      s2, _, _ = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/session",
        HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
      )
      s2.should eq 200

      # 3. Cookie-authenticated POST /queues without X-Requested-With -> 403 code: "csrf"
      s3, _, b3 = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/queues",
        HTTP::Headers{"X-Test-Auth" => "cookie"}
      )
      s3.should eq 403
      JSON.parse(b3)["error"]["code"].should eq "csrf"

      # 4. Cookie-authenticated POST /queues with X-Requested-With -> 200
      s4, _, _ = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/queues",
        HTTP::Headers{"X-Test-Auth" => "cookie", "X-Requested-With" => "1"}
      )
      s4.should eq 200

      # 5. Bearer-authenticated POST /queues without X-Requested-With -> 200 (exempt)
      s5, _, _ = invoke_app(
        app,
        app.default_handlers,
        "POST",
        "/queues",
        HTTP::Headers{"X-Test-Auth" => "bearer"}
      )
      s5.should eq 200

      # 6. csrf_exempt: true route without X-Requested-With -> 200
      s6, _, _ = invoke_app(app, app.default_handlers, "POST", "/webhooks")
      s6.should eq 200
    end
  end

  describe "strict RequestId validation" do
    it "accepts 1..64 char plain ASCII IDs and replaces empty, oversized, or non-conforming IDs when strict" do
      handler = Azu::Handler::RequestId.new(strict: true, max_length: 64)
      seen_id : String? = nil
      handler.next = ->(ctx : HTTP::Server::Context) do
        seen_id = Azu::RequestContext.current_id(ctx)
      end

      # Valid plain ID
      req_ok = HTTP::Request.new("GET", "/test", HTTP::Headers{"X-Request-ID" => "req_abc-123.45:67"})
      ctx_ok = HTTP::Server::Context.new(req_ok, HTTP::Server::Response.new(IO::Memory.new))
      handler.call(ctx_ok)
      ctx_ok.response.headers["X-Request-ID"].should eq "req_abc-123.45:67"
      seen_id.should eq "req_abc-123.45:67"

      # Invalid IDs (empty, > 64 chars, spaces, unicode, punctuation outside [A-Za-z0-9._:-])
      ["", "a" * 65, "bad id with spaces", "req-αβγ", "req/123", "req;drop"].each do |invalid_id|
        req = HTTP::Request.new("GET", "/test", HTTP::Headers{"X-Request-ID" => invalid_id})
        ctx = HTTP::Server::Context.new(req, HTTP::Server::Response.new(IO::Memory.new))
        handler.call(ctx)
        actual = ctx.response.headers["X-Request-ID"]
        actual.should_not eq invalid_id
        actual.should start_with("req_")
      end
    end
  end

  describe "observability (on_response) and audit (on_audit) hooks" do
    it "emits RequestEvent with route_pattern for matched routes and nil for 404/405/401" do
      events = [] of Azu::Instrumentation::RequestEvent

      app = Azu::App.new
      app.config.router.method_not_allowed = true
      app.config.on_response { |event| events << event }
      app.router.get "/users/:id", HygieneSimpleEndpoint.new, public: true

      invoke_app(app, app.default_handlers, "GET", "/users/42")
      invoke_app(app, app.default_handlers, "DELETE", "/users/42")
      invoke_app(app, app.default_handlers, "GET", "/no-such-route")

      events.size.should eq 3
      events[0].status.should eq 200
      events[0].route_pattern.should eq "/users/:id"
      events[0].path.should eq "/users/42"

      events[1].status.should eq 405
      events[1].route_pattern.should be_nil

      events[2].status.should eq 404
      events[2].route_pattern.should be_nil
    end

    it "emits AuditEvent outcomes, enforces audit_critical: true (503 on failure), and rate-limits anonymous audit events" do
      audit_events = [] of Azu::Instrumentation::AuditEvent
      fail_audit_store = Atomic(Bool).new(false)
      critical_ep = HygieneSimpleEndpoint.new

      app = Azu::App.new
      app.config.error_format = Azu::ErrorFormat::Envelope
      app.config.auth.enabled = true
      app.config.auth.roles = [:operator, :admin]
      app.config.auth.default_write_role = :operator
      app.config.auth.authenticator = Azu::Auth::BearerAuthenticator.new({
        "op"    => Azu::Auth::Identity.new("op-1", roles: ["operator"]),
        "admin" => Azu::Auth::Identity.new("admin-1", roles: ["admin"]),
      })
      app.config.audit.anonymous_rate_limit = 2
      app.config.on_audit do |event|
        raise "audit db down" if fail_audit_store.get && event.outcome.pending?
        audit_events << event
      end

      app.router.post "/queues/purge", critical_ep,
        requires: Azu::Access.role(:admin),
        audit_action: "queues.purge",
        audit_critical: true
      app.router.post "/login", HygieneSimpleEndpoint.new,
        public: true,
        audit_action: "session.login"

      # 1. Critical audit route when store is healthy -> emits Pending then Succeeded, runs endpoint
      s_ok, _, b_ok = invoke_app(app, app.default_handlers, "POST", "/queues/purge", HTTP::Headers{"Authorization" => "Bearer admin"})
      s_ok.should eq 200
      b_ok.should eq "called:1"
      audit_events.map(&.outcome).should eq [
        Azu::Instrumentation::AuditOutcome::Pending,
        Azu::Instrumentation::AuditOutcome::Succeeded,
      ]
      audit_events.last.action.should eq "queues.purge"
      audit_events.last.principal.try(&.id).should eq "admin-1"

      # 2. Critical audit route when store fails on Pending -> refuses with 503 BEFORE action runs!
      audit_events.clear
      fail_audit_store.set(true)
      s_503, _, b_503 = invoke_app(app, app.default_handlers, "POST", "/queues/purge", HTTP::Headers{"Authorization" => "Bearer admin"})
      s_503.should eq 503
      JSON.parse(b_503)["error"]["code"].should eq "audit_unavailable"
      critical_ep.calls.size.should eq 1 # did NOT run action!
      fail_audit_store.set(false)

      # 3. Denied (403) audit outcome on insufficient role
      audit_events.clear
      s_403, _, _ = invoke_app(app, app.default_handlers, "POST", "/queues/purge", HTTP::Headers{"Authorization" => "Bearer op"})
      s_403.should eq 403
      audit_events.last.outcome.should eq Azu::Instrumentation::AuditOutcome::Denied
      audit_events.last.error_code.should eq "forbidden"

      # 4. Anonymous audit rate limit: allows 2, 3rd emits audit.rate_limited, 4th is suppressed
      audit_events.clear
      4.times do
        invoke_app(app, app.default_handlers, "POST", "/login", HTTP::Headers{"X-Forwarded-For" => "203.0.113.9"})
      end
      audit_events.size.should eq 3
      audit_events[0].action.should eq "session.login"
      audit_events[1].action.should eq "session.login"
      audit_events[2].action.should eq "audit.rate_limited"
      audit_events[2].outcome.should eq Azu::Instrumentation::AuditOutcome::RateLimited
    end
  end
end
