require "http/server"
require "../method"
require "./principal"

module Azu
  # Declarative route access requirements (ordered roles and permission sets).
  #
  # ```
  # app.router.get "/queues", ListEndpoint.new(queues),
  #   requires: Azu::Access.role(:viewer),
  #   summary: "List the queues"
  #
  # app.router.post "/queues/:name/purge", PurgeEndpoint.new(queues),
  #   requires: Azu::Access.role(:operator) & Azu::Access.permissions("queues:purge")
  # ```
  module Access
    struct Requirement
      getter roles : Array(String)
      getter all_permissions : Array(String)
      getter any_permissions : Array(String)

      def initialize(
        role : String? = nil,
        @all_permissions : Array(String) = [] of String,
        @any_permissions : Array(String) = [] of String,
        *,
        roles : Array(String)? = nil,
      )
        @roles = roles || (role ? [role] : [] of String)
      end

      # Primary required role (or `nil` when none was set).
      def role : String?
        @roles.first?
      end

      # Combines two requirements so both must hold.
      def &(other : Requirement) : Requirement
        Requirement.new(
          roles: other.roles.empty? ? @roles : other.roles,
          all_permissions: (@all_permissions + other.all_permissions).uniq,
          any_permissions: (@any_permissions + other.any_permissions).uniq
        )
      end

      # True when `principal` satisfies the role and permission rules of this requirement.
      # When `role_hierarchy` is non-empty (ordered from lowest to highest privilege), a principal
      # holding a role at or above a required role's index satisfies the role check.
      def satisfied_by?(principal : Auth::Principal, role_hierarchy : Array(String) = [] of String) : Bool
        unless @roles.empty?
          return false unless @roles.any? { |req_role| role_satisfied?(principal, req_role, role_hierarchy) }
        end

        unless @all_permissions.empty?
          return false unless @all_permissions.all? { |perm| principal.has_permission?(perm) }
        end

        unless @any_permissions.empty?
          return false unless @any_permissions.any? { |perm| principal.has_permission?(perm) }
        end

        true
      end

      # Human-readable summary used in OpenAPI descriptions and error diagnostics.
      def summary : String
        parts = [] of String
        if @roles.size == 1
          parts << "role `#{@roles.first}`"
        elsif @roles.size > 1
          parts << "role in #{@roles.map { |role_name| "`#{role_name}`" }.join(", ")}"
        end
        parts << "permissions #{@all_permissions.map { |perm| "`#{perm}`" }.join(", ")}" unless @all_permissions.empty?
        parts << "any permission of #{@any_permissions.map { |perm| "`#{perm}`" }.join(", ")}" unless @any_permissions.empty?
        parts.empty? ? "authenticated" : parts.join(" and ")
      end

      private def role_satisfied?(principal : Auth::Principal, required : String, hierarchy : Array(String)) : Bool
        if !hierarchy.empty? && (req_idx = hierarchy.index(required))
          principal.roles.any? do |held|
            if held == required
              true
            elsif held_idx = hierarchy.index(held)
              held_idx >= req_idx
            else
              false
            end
          end
        else
          principal.has_role?(required)
        end
      end
    end

    # Requires at least `role` (or any of the given `roles`, or a higher role in `config.auth.roles`).
    def self.role(*roles : Symbol | String) : Requirement
      Requirement.new(roles: roles.map(&.to_s).to_a)
    end

    # Requires any of the given `roles` (or a higher role in `config.auth.roles`).
    def self.role(roles : Enumerable) : Requirement
      Requirement.new(roles: roles.map(&.to_s).to_a)
    end

    # Requires all listed permissions.
    def self.permissions(*permissions : Symbol | String) : Requirement
      Requirement.new(all_permissions: permissions.map(&.to_s).to_a)
    end

    # Requires all listed permissions.
    def self.permissions(permissions : Enumerable) : Requirement
      Requirement.new(all_permissions: permissions.map(&.to_s).to_a)
    end

    # Requires at least one of the listed permissions.
    def self.any_permission(*permissions : Symbol | String) : Requirement
      Requirement.new(any_permissions: permissions.map(&.to_s).to_a)
    end

    # Requires at least one of the listed permissions.
    def self.any_permission(permissions : Enumerable) : Requirement
      Requirement.new(any_permissions: permissions.map(&.to_s).to_a)
    end

    # OAuth 2.0 alias for `permissions`: requires all listed scopes.
    def self.scopes(*scopes : Symbol | String) : Requirement
      permissions(*scopes)
    end

    # OAuth 2.0 alias for `permissions`: requires all listed scopes.
    def self.scopes(scopes : Enumerable) : Requirement
      permissions(scopes)
    end

    # OAuth 2.0 alias for `any_permission`: requires at least one of the listed scopes.
    def self.any_scope(*scopes : Symbol | String) : Requirement
      any_permission(*scopes)
    end

    # OAuth 2.0 alias for `any_permission`: requires at least one of the listed scopes.
    def self.any_scope(scopes : Enumerable) : Requirement
      any_permission(scopes)
    end

    # Requires an authenticated principal without a specific role or permission constraint.
    def self.authenticated : Requirement
      Requirement.new
    end
  end

  # Composable metadata and security options for a route, scope, or `Azu::Endpoint`.
  #
  # Options compose in three layers:
  # `scope_defaults.merge(endpoint.route_options).merge(call_site_options)`.
  struct RouteOptions
    getter requires : Access::Requirement?
    getter public : Bool?
    getter enrolment_exempt : Bool?
    getter csrf_exempt : Bool?
    getter audit : Bool?
    getter audit_action : String?
    getter audit_critical : Bool?
    getter summary : String?
    getter description : String?
    getter max_body_size : UInt64?
    getter content_types : Array(String)?
    getter success_status : Int32?

    def initialize(
      requires : Access::Requirement? = nil,
      @public : Bool? = nil,
      @enrolment_exempt : Bool? = nil,
      @csrf_exempt : Bool? = nil,
      @audit : Bool? = nil,
      @audit_action : String? = nil,
      @audit_critical : Bool? = nil,
      @summary : String? = nil,
      @description : String? = nil,
      @max_body_size : UInt64? = nil,
      @content_types : Array(String)? = nil,
      @success_status : Int32? = nil,
      *,
      role : Symbol | String | Nil = nil,
      roles : Enumerable? = nil,
      permissions : Enumerable? = nil,
      any_permission : Enumerable? = nil,
      scopes : Enumerable? = nil,
      any_scope : Enumerable? = nil,
    )
      req = combine_requirement(requires, role) { |val| Access.role(val) }
      req = combine_requirement(req, roles) { |val| Access.role(val) }
      req = combine_requirement(req, permissions) { |val| Access.permissions(val) }
      req = combine_requirement(req, any_permission) { |val| Access.any_permission(val) }
      req = combine_requirement(req, scopes) { |val| Access.scopes(val) }
      req = combine_requirement(req, any_scope) { |val| Access.any_scope(val) }
      @requires = (@public == true) ? nil : req
    end

    private def combine_requirement(existing : Access::Requirement?, value, &) : Access::Requirement?
      return existing unless value
      added = yield value
      existing ? (existing & added) : added
    end

    def public? : Bool
      @public || false
    end

    def enrolment_exempt? : Bool
      @enrolment_exempt || false
    end

    def csrf_exempt? : Bool
      @csrf_exempt || false
    end

    def audit_critical? : Bool
      @audit_critical || false
    end

    # Combines `req` with any existing `requires` on this `RouteOptions` using `Requirement#&`
    # and marks `public` as `false`. Used by declarative macros inside `Azu::Endpoint`.
    def with_requirement(req : Access::Requirement) : RouteOptions
      combined = @requires.try { |existing| existing & req } || req
      copy_with(requires: combined, public: false)
    end

    # Returns a new `RouteOptions` where fields explicitly set on `other` override `self`.
    # If `other` sets `public: true`, any inherited `requires` is cleared.
    # If `other` sets `requires` without setting `public: true`, `public` becomes `false`.
    def merge(other : RouteOptions) : RouteOptions
      merged_public, merged_requires = merge_access(other)

      RouteOptions.new(
        requires: merged_requires,
        public: merged_public,
        enrolment_exempt: pick_bool(other.enrolment_exempt, @enrolment_exempt),
        csrf_exempt: pick_bool(other.csrf_exempt, @csrf_exempt),
        audit: pick_bool(other.audit, @audit),
        audit_action: other.audit_action || @audit_action,
        audit_critical: pick_bool(other.audit_critical, @audit_critical),
        summary: other.summary || @summary,
        description: other.description || @description,
        max_body_size: other.max_body_size || @max_body_size,
        content_types: other.content_types || @content_types,
        success_status: other.success_status || @success_status,
      )
    end

    private def merge_access(other : RouteOptions) : Tuple(Bool?, Access::Requirement?)
      return {true, nil} if other.public == true

      combined_req = if (r1 = @requires) && (r2 = other.requires)
                       r1 & r2
                     else
                       other.requires || @requires
                     end
      if other.public == false || !other.requires.nil?
        {false, combined_req}
      else
        {@public, (@public == true) ? nil : @requires}
      end
    end

    private def pick_bool(override : Bool?, fallback : Bool?) : Bool?
      override.nil? ? fallback : override
    end

    # Returns a copy of `self` with selected fields updated.
    def copy_with(
      requires : Access::Requirement? = @requires,
      public : Bool? = @public,
      enrolment_exempt : Bool? = @enrolment_exempt,
      csrf_exempt : Bool? = @csrf_exempt,
      audit : Bool? = @audit,
      audit_action : String? = @audit_action,
      audit_critical : Bool? = @audit_critical,
      summary : String? = @summary,
      description : String? = @description,
      max_body_size : UInt64? = @max_body_size,
      content_types : Array(String)? = @content_types,
      success_status : Int32? = @success_status,
    ) : RouteOptions
      RouteOptions.new(
        requires: requires,
        public: public,
        enrolment_exempt: enrolment_exempt,
        csrf_exempt: csrf_exempt,
        audit: audit,
        audit_action: audit_action,
        audit_critical: audit_critical,
        summary: summary,
        description: description,
        max_body_size: max_body_size,
        content_types: content_types,
        success_status: success_status,
      )
    end
  end

  # Configuration for audit logging (`c.audit`).
  class AuditConfiguration
    # Whether the `Auth::AuditHook` is enabled.
    property? enabled : Bool = false

    # Optional rate limit on anonymous (unauthenticated) audit events per client address per `anonymous_rate_window`.
    # When exceeded, suppresses further anonymous events in the window and emits one `"audit.rate_limited"` event.
    property anonymous_rate_limit : Int32? = nil

    # Time window for `anonymous_rate_limit`.
    property anonymous_rate_window : Time::Span = 1.minute

    # Error code returned with `503 Service Unavailable` when an `audit_critical: true` pre-action write fails.
    property critical_error_code : String = "audit_unavailable"

    # Error message returned with `503 Service Unavailable` when an `audit_critical: true` pre-action write fails.
    property critical_error_message : String = "Audit log unavailable"
  end

  module Auth
    abstract class Authenticator
    end

    # Configuration for authentication, role hierarchy, per-verb access defaults, and enrolment gates.
    class Configuration
      @enabled : Bool = false
      @enabled_explicit : Bool = false

      # Enables the preset auth pipeline in `App#default_handlers`.
      # Automatically becomes `true` when an authenticator is configured unless explicitly set to `false`.
      def enabled? : Bool
        @enabled
      end

      def enabled=(value : Bool) : Bool
        @enabled_explicit = true
        @enabled = value
      end

      # The authenticator used by `Handler::Authentication` when none is passed explicitly.
      property authenticator : Authenticator? = nil

      # Enables `c.auth` unless `c.auth.enabled = false` was explicitly set by the caller.
      protected def enable_by_convention! : Nil
        @enabled = true unless @enabled_explicit
      end

      # When `true`, mounts Authly's OAuth 2.0 / OIDC provider endpoints on `router` at boot.
      property? oauth_provider : Bool = false

      # Ordered role names from lowest to highest privilege (e.g. `["viewer", "operator", "admin"]`).
      getter roles : Array(String) = [] of String

      # Single underlying per-verb default requirement table.
      getter verb_defaults : Hash(Azu::Method, Access::Requirement) = {} of Azu::Method => Access::Requirement

      # Fallback default requirement when no per-verb entry in `verb_defaults` matches.
      property default_access : Access::Requirement? = nil

      # Optional custom enrolment gate proc returning `true` when access is allowed or `false` when enrolment is pending.
      # When `nil`, `principal.enrolment_pending?` is checked.
      property enrolment_gate : Proc(Principal, Router::Route, Bool)? = nil

      # Error code emitted on `403` when an account fails the enrolment gate (e.g. `"mfa_enrolment_required"`).
      property enrolment_error_code : String = "enrolment_required"

      # Error message emitted on `403` when an account fails the enrolment gate.
      property enrolment_error_message : String = "Account enrolment must be completed before accessing this resource"

      # Default error code and message for `401` and `403`.
      property unauthorized_code : String = "unauthorized"
      property unauthorized_message : String = "Authentication required"
      property www_authenticate : String = "Bearer"
      property forbidden_code : String = "forbidden"
      property forbidden_message : String = "Insufficient permissions"

      # OpenAPI security scheme name emitted in `components.securitySchemes` and operation `security`.
      property security_scheme_name : String = "bearerAuth"

      # Optional OpenAPI `bearerFormat` (e.g. `"JWT"`) emitted on the HTTP bearer security scheme.
      property bearer_format : String? = nil

      # When `true`, appends a human-readable access requirement summary to OpenAPI operation `description`.
      property? document_requirements_in_description : Bool = false

      # Sets the ordered role hierarchy from lowest to highest privilege.
      def roles=(list : Enumerable) : Array(String)
        @roles = list.map(&.to_s).to_a
      end

      # Conventional role hierarchy setup: sets `roles` from lowest to highest privilege and,
      # unless per-verb or default access was already customized, automatically configures
      # `default_read_role` (`GET`/`HEAD`) to the lowest role and `default_write_role`
      # (`POST`/`PUT`/`PATCH`/`DELETE`) to the second role (or the sole role when only one is given).
      def role_hierarchy(*roles : Symbol | String) : Array(String)
        role_hierarchy(roles)
      end

      # Conventional role hierarchy setup from an `Enumerable`.
      def role_hierarchy(list : Enumerable) : Array(String)
        self.roles = list
        if @verb_defaults.empty? && @default_access.nil? && !@roles.empty?
          self.default_read_role = @roles.first
          self.default_write_role = @roles[1]? || @roles.first
        end
        @roles
      end

      # Returns the index of `role` in `roles` (0 = lowest privilege), or `nil` if unknown.
      def role_index(role : Symbol | String) : Int32?
        @roles.index(role.to_s)
      end

      # Sets the default requirement for a single HTTP verb.
      def default_access(verb : Azu::Method | Symbol | String, requirement : Access::Requirement) : Access::Requirement
        method = verb.is_a?(Azu::Method) ? verb : Azu::Method.parse(verb.to_s)
        @verb_defaults[method] = requirement
      end

      # Sets the default role for a single HTTP verb.
      def default_role(verb : Azu::Method | Symbol | String, role : Symbol | String) : Access::Requirement
        default_access(verb, Access.role(role))
      end

      # Looks up the per-verb default requirement for `method`, falling back to `default_access`.
      def default_access_for(method : Azu::Method) : Access::Requirement?
        found = if method.web_socket?
                  @verb_defaults[Azu::Method::WebSocket]? || @verb_defaults[Azu::Method::Get]?
                else
                  @verb_defaults[method]?
                end
        found || @default_access
      end

      # Convenience setter writing `GET` and `HEAD` entries in `verb_defaults`.
      def default_read_access=(requirement : Access::Requirement) : Access::Requirement
        @verb_defaults[Azu::Method::Get] = requirement
        @verb_defaults[Azu::Method::Head] = requirement
        requirement
      end

      # Convenience setter writing `Access.role(role)` for `GET` and `HEAD` in `verb_defaults`.
      def default_read_role=(role : Symbol | String) : Access::Requirement
        self.default_read_access = Access.role(role)
      end

      # Convenience setter writing `POST`, `PUT`, `PATCH`, and `DELETE` entries in `verb_defaults`.
      def default_write_access=(requirement : Access::Requirement) : Access::Requirement
        @verb_defaults[Azu::Method::Post] = requirement
        @verb_defaults[Azu::Method::Put] = requirement
        @verb_defaults[Azu::Method::Patch] = requirement
        @verb_defaults[Azu::Method::Delete] = requirement
        requirement
      end

      # Convenience setter writing `Access.role(role)` for `POST`, `PUT`, `PATCH`, and `DELETE` in `verb_defaults`.
      def default_write_role=(role : Symbol | String) : Access::Requirement
        self.default_write_access = Access.role(role)
      end
    end
  end
end
