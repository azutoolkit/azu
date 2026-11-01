require "http/server/handler"
require "../router"
require "../auth/access"
require "../auth/authenticator"
require "../instrumentation"
require "../response"
require "../request_context"
require "../log_text"

module Azu
  module Auth
    # Marker module included by `Azu::Handler::Authentication`.
    # Custom application authentication handlers may also `include Azu::Auth::AuthenticationStage`
    # so `App#validate_pipeline!` recognizes them at boot.
    module AuthenticationStage
    end

    # Post-routing authorization hook (`Router::Hook`) that runs after `404`/`405` and before
    # the endpoint action.
    #
    # Checks:
    # 1. `route.effective_requirement(auth_config)` against `context.principal?` (`403` with `code: "forbidden"`).
    # 2. The enrolment gate (`principal.enrolment_pending?` or `auth_config.enrolment_gate`) unless
    #    `route.enrolment_exempt?` or `route.public?` (`403` with `auth_config.enrolment_error_code`).
    class Authorize
      include Router::Hook

      def initialize(@config : Azu::Configuration? = nil)
      end

      def call(context : HTTP::Server::Context, route : Router::Route) : Nil
        return if route.public?
        return if context.request.method == "OPTIONS" && !route.method.options?

        cfg = @config || Azu.current_config
        auth = cfg.auth

        principal = context.principal?
        unless principal
          raise Response::AuthenticationError.new(
            auth.unauthorized_message,
            code: auth.unauthorized_code,
            www_authenticate: auth.www_authenticate
          )
        end

        if req = route.effective_requirement(auth)
          unless req.satisfied_by?(principal, auth.roles)
            raise Response::AuthorizationError.new(
              auth.forbidden_message,
              code: auth.forbidden_code
            )
          end
        end

        unless route.enrolment_exempt?
          enrolment_blocked = if gate = auth.enrolment_gate
                                !gate.call(principal, route)
                              else
                                principal.enrolment_pending?
                              end
          if enrolment_blocked
            raise Response::AuthorizationError.new(
              auth.enrolment_error_message,
              code: auth.enrolment_error_code
            )
          end
        end
      end
    end

    # Post-routing around/after hook that records structured `Instrumentation::AuditEvent` records
    # for state-changing requests and routes configured with `audit_action:` or `audit_critical: true`.
    class AuditHook
      include Router::Hook

      STATE_CHANGING_METHODS = %w(POST PUT PATCH DELETE)

      private struct RateBucket
        property count : Int32
        property window_start : Time::Instant

        def initialize(@count : Int32, @window_start : Time::Instant)
        end
      end

      @buckets = Hash(String, RateBucket).new
      @buckets_mutex = Mutex.new

      def initialize(@config : Azu::Configuration? = nil)
      end

      # Pre-action hook: for `audit_critical: true` routes, writes a `:pending` audit record first
      # and refuses the request with `503 Service Unavailable` (`code: "audit_unavailable"`) if the write fails.
      def around(context : HTTP::Server::Context, route : Router::Route, &) : Nil
        if route.audit_critical?
          cfg = @config || Azu.current_config
          pending_event = build_event(
            context: context,
            route: route,
            status: 0,
            outcome: Instrumentation::AuditOutcome::Pending,
            error_code: nil,
            duration: Time::Span.zero
          )
          begin
            cfg.emit_audit!(pending_event)
            Instrumentation.report_audit!(pending_event)
          rescue
            raise Response::ServiceUnavailable.new(
              cfg.audit.critical_error_message,
              code: cfg.audit.critical_error_code
            )
          end
        end

        yield
      end

      # Post-action hook (`Router::Hook` interface): records the final outcome.
      def after(
        context : HTTP::Server::Context,
        route : Router::Route,
        error : Response::Error?,
      ) : Nil
        duration = Time.instant - context.azu_started_at
        after(context, route, duration, error)
      end

      # Post-action hook with explicit duration: records the final outcome (`Succeeded`, `Denied`, `RateLimited`, `Failed`).
      def after(
        context : HTTP::Server::Context,
        route : Router::Route,
        duration : Time::Span,
        error : Response::Error?,
      ) : Nil
        cfg = @config || Azu.current_config
        return unless cfg.audit_listening?
        return unless auditable_route?(context, route)

        status = error.try(&.status.code) || context.response.status_code
        error_code = error.try(&.code)
        outcome = outcome_for(status)

        emit_with_rate_limit(
          cfg,
          build_event(
            context: context,
            route: route,
            status: status,
            outcome: outcome,
            error_code: error_code,
            duration: duration
          )
        )
      end

      # Emits an audit event for requests on state-changing methods that did not reach a leaf route
      # (such as pre-routing `401` or authenticated `404`/`405`).
      def emit_unmatched(
        context : HTTP::Server::Context,
        duration : Time::Span,
        error : Response::Error? = nil,
      ) : Nil
        cfg = @config || Azu.current_config
        return unless cfg.audit_listening?
        return unless STATE_CHANGING_METHODS.includes?(context.request.method.upcase)

        status = error.try(&.status.code) || context.response.status_code
        return if context.principal.nil? && status != 401 && status != 403

        error_code = error.try(&.code) || default_error_code_for(status)
        outcome = outcome_for(status)

        emit_with_rate_limit(
          cfg,
          Instrumentation::AuditEvent.new(
            action: nil,
            method: context.request.method.upcase,
            route_pattern: nil,
            path: context.request.path,
            principal: context.principal,
            status: status,
            outcome: outcome,
            error_code: error_code,
            duration: duration,
            request_id: RequestContext.current_id(context),
            client_address: client_ip(context)
          )
        )
      end

      # Resets anonymous rate-limit buckets (for specs).
      def reset_rate_limits! : Nil
        @buckets_mutex.synchronize { @buckets.clear }
      end

      private def auditable_route?(context : HTTP::Server::Context, route : Router::Route) : Bool
        return false if route.audit == false
        return true if route.audit == true
        STATE_CHANGING_METHODS.includes?(context.request.method.upcase) ||
          !route.audit_action.nil? ||
          route.audit_critical?
      end

      private def outcome_for(status : Int32) : Instrumentation::AuditOutcome
        case status
        when 401, 403
          Instrumentation::AuditOutcome::Denied
        when 429
          Instrumentation::AuditOutcome::RateLimited
        when 200..399
          Instrumentation::AuditOutcome::Succeeded
        else
          Instrumentation::AuditOutcome::Failed
        end
      end

      private def default_error_code_for(status : Int32) : String?
        case status
        when 401 then "unauthorized"
        when 403 then "forbidden"
        when 404 then "not_found"
        when 405 then "method_not_allowed"
        when 429 then "rate_limited"
        else          nil
        end
      end

      private def build_event(
        context : HTTP::Server::Context,
        route : Router::Route,
        status : Int32,
        outcome : Instrumentation::AuditOutcome,
        error_code : String?,
        duration : Time::Span,
      ) : Instrumentation::AuditEvent
        pattern = context.route_pattern || route.path
        action = route.audit_action || "#{context.request.method.upcase} #{pattern}"
        Instrumentation::AuditEvent.new(
          action: action,
          method: context.request.method.upcase,
          route_pattern: pattern,
          path: context.request.path,
          principal: context.principal,
          status: status,
          outcome: outcome,
          error_code: error_code,
          duration: duration,
          request_id: RequestContext.current_id(context),
          client_address: client_ip(context)
        )
      end

      private def emit_with_rate_limit(cfg : Azu::Configuration, event : Instrumentation::AuditEvent) : Nil
        if event.principal.nil? && (limit = cfg.audit.anonymous_rate_limit)
          key = event.client_address || "unknown"
          window = cfg.audit.anonymous_rate_window
          now = Time.instant
          count = @buckets_mutex.synchronize do
            bucket = @buckets[key]?
            if bucket.nil? || (now - bucket.window_start) >= window
              @buckets[key] = RateBucket.new(1, now)
              1
            else
              next_count = bucket.count + 1
              @buckets[key] = RateBucket.new(next_count, bucket.window_start)
              next_count
            end
          end

          if count == limit + 1
            rate_limited_event = Instrumentation::AuditEvent.new(
              action: "audit.rate_limited",
              method: event.method,
              route_pattern: event.route_pattern,
              path: event.path,
              principal: nil,
              status: event.status,
              outcome: Instrumentation::AuditOutcome::RateLimited,
              error_code: "audit.rate_limited",
              duration: event.duration,
              request_id: event.request_id,
              client_address: event.client_address
            )
            cfg.emit_audit(rate_limited_event)
            Instrumentation.report_audit(rate_limited_event)
            return
          elsif count > limit + 1
            return
          end
        end

        cfg.emit_audit(event)
        Instrumentation.report_audit(event)
      end

      private def client_ip(context : HTTP::Server::Context) : String?
        if forwarded = context.request.headers["X-Forwarded-For"]?
          first = forwarded.split(',').first?.try(&.strip)
          return first if first && !first.empty?
        end
        context.request.remote_address.try(&.to_s)
      end
    end
  end

  module Handler
    # Pre-routing authentication middleware (`401` before `404`/`405`).
    #
    # - Checks `router.public_route?(context)` first (which memoizes the route lookup on `context`
    #   so `Router#process` never matches twice). If the exact `(verb, path)` is `public: true`
    #   (or an `OPTIONS` preflight on a path with a public route, or `HEAD` on a public `GET`),
    #   authentication is skipped and headers are ignored.
    # - Otherwise runs the configured `Auth::Authenticator` and `principal.valid?(context)`,
    #   attaching `context.principal` or answering `401 Unauthorized` before routing reveals
    #   whether the target path or method exists.
    class Authentication
      include HTTP::Handler
      include Auth::AuthenticationStage

      private LOG = ::Log.for("Azu::Handler::Authentication")

      getter authenticator : Auth::Authenticator?

      def initialize(@authenticator : Auth::Authenticator? = nil, @config : Configuration? = nil)
      end

      def self.new(config : Configuration) : self
        new(nil, config)
      end

      def self.new(&block : HTTP::Server::Context -> Auth::Principal?) : self
        new(Auth::ProcAuthenticator.new(block))
      end

      def call(context : HTTP::Server::Context)
        cfg = @config || Azu.current_config
        if cfg.router.public_route?(context)
          call_next(context)
          return
        end

        auth_cfg = cfg.auth
        auth = @authenticator || auth_cfg.authenticator

        begin
          unless auth
            raise Response::AuthenticationError.new(
              auth_cfg.unauthorized_message,
              code: auth_cfg.unauthorized_code,
              www_authenticate: auth_cfg.www_authenticate
            )
          end

          principal = auth.authenticate(context)
          unless principal
            raise Response::AuthenticationError.new(
              auth_cfg.unauthorized_message,
              code: auth_cfg.unauthorized_code,
              www_authenticate: auth_cfg.www_authenticate
            )
          end

          unless principal.valid?(context)
            raise Response::AuthenticationError.new(
              "Credentials are no longer valid",
              code: auth_cfg.unauthorized_code,
              www_authenticate: auth_cfg.www_authenticate
            )
          end

          context.principal = principal
        rescue ex : Response::AuthenticationError
          context.azu_last_error = ex
          LogText.log_client_error(LOG, ex.status_code) do
            LogText.client_error_line(context.request.method, context.request.path, ex.status_code, ex.title)
          end
          ex.to_s(context)
          cfg.report_unmatched_and_response_for(context) unless context.azu_in_app_scope?
          return
        end

        call_next(context)
      end
    end
  end
end
