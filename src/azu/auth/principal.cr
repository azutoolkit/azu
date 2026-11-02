require "http/server"
require "json"

module Azu
  module Auth
    # Base reference type representing an authenticated caller.
    #
    # Subclass `Principal` for domain-specific account or token principals, or use
    # `Azu::Auth::Identity` directly. Because `Principal` is a `class` (reference type),
    # storing `principal : Principal?` on `HTTP::Server::Context` is always an 8-byte
    # pointer with zero struct-in-module-field union overhead.
    abstract class Principal
      # Unique identifier of the authenticated subject.
      abstract def id : String

      # Optional human-readable display name or username.
      def name : String?
        nil
      end

      # Roles granted to this principal (e.g. `["viewer"]`, `["operator"]`).
      def roles : Enumerable(String)
        [] of String
      end

      # Fine-grained permissions (or OAuth 2.0 scopes) granted to this principal
      # (e.g. `["queues:read", "queues:write"]`).
      def permissions : Enumerable(String)
        [] of String
      end

      # OAuth 2.0 scopes granted to this principal (alias for `permissions`).
      def scopes : Enumerable(String)
        permissions
      end

      # Raw verified token claims, if any.
      def claims : Hash(String, JSON::Any)
        {} of String => JSON::Any
      end

      # How the principal was authenticated (`:bearer`, `:jwt`, `:cookie`, `:api_key`, etc.).
      # Used by the CSRF header guard to exempt non-cookie credentials while protecting `:cookie` sessions.
      def auth_scheme : Symbol
        :bearer
      end

      # True when the account must complete an enrolment step (such as MFA setup or password reset)
      # before accessing routes that are not `enrolment_exempt: true` or `public: true`.
      def enrolment_pending? : Bool
        false
      end

      # Per-request account validity hook (e.g. checking revocation or demotion).
      # Returning `false` causes the authentication stage to reject the request with `401`.
      def valid?(context : HTTP::Server::Context) : Bool
        true
      end

      # True when `roles` contains `role` (exact match; ordered hierarchy checks use `Access::Requirement`).
      def has_role?(role : String | Symbol) : Bool
        target = role.to_s
        roles.any? { |entry| entry == target }
      end

      # True when `permissions` contains `permission`.
      def has_permission?(permission : String | Symbol) : Bool
        target = permission.to_s
        permissions.any? { |entry| entry == target }
      end

      # True when `scopes` (`permissions`) contains `scope`.
      def has_scope?(scope : String | Symbol) : Bool
        has_permission?(scope)
      end

      # True when the principal has completed multi-factor or cryptographic challenge-response authentication.
      def mfa_verified? : Bool
        false
      end

      # Authentication Methods References (RFC 8176 `amr` claim, e.g. `["pwd", "mfa"]`, `["challenge_response"]`).
      def amr : Enumerable(String)
        [] of String
      end

      # Authentication Context Class Reference (`acr` claim, e.g. `"aal2"`, `"mfa"`).
      def acr : String?
        nil
      end

      # Upstream identity/social provider name (e.g. `"google"`, `"github"`, `"apple"`), if any.
      def auth_provider : String?
        nil
      end

      # Upstream social provider subject identifier (`"social_uid"` claim), if any.
      def social_uid : String?
        nil
      end

      # True when `amr` contains `method` (case-insensitive).
      def has_amr?(method : String | Symbol) : Bool
        target = method.to_s.downcase
        amr.any? { |entry| entry.downcase == target }
      end

      # True when authenticated via Authly cryptographic challenge-response.
      def challenge_authenticated? : Bool
        has_amr?("challenge_response") || has_amr?("urn:ietf:params:oauth:grant-type:challenge")
      end

      # True when authenticated via an external social identity provider.
      def social_authenticated? : Bool
        !auth_provider.nil? || has_amr?("social") || has_amr?("urn:ietf:params:oauth:grant-type:social")
      end
    end

    # Concrete, ready-to-use `Principal` for bearer tokens, JWT/Authly claims, or session users.
    class Identity < Principal
      DEFAULT_MFA_AMR = {
        "mfa",
        "otp",
        "totp",
        "hwk",
        "swk",
        "fido",
        "webauthn",
        "challenge_response",
        "urn:ietf:params:oauth:grant-type:challenge",
        "sms",
        "pin",
      }

      DEFAULT_MFA_ACR = {
        "aal2",
        "aal3",
        "phr",
        "phrh",
        "mfa",
        "urn:mace:incommon:iap:silver",
      }

      getter id : String
      getter name : String?
      getter roles : Array(String)
      getter permissions : Array(String)
      getter auth_scheme : Symbol
      getter? enrolment_pending : Bool
      getter? mfa_verified : Bool
      getter amr : Array(String)
      getter acr : String?
      getter auth_provider : String?
      getter social_uid : String?
      getter email : String?
      getter? email_verified : Bool
      getter key_id : String?
      getter metadata : Hash(String, String)
      getter claims : Hash(String, JSON::Any)
      @validator : Proc(HTTP::Server::Context, Bool)?

      def initialize(
        @id : String,
        @name : String? = nil,
        roles = [] of String,
        permissions = [] of String,
        *,
        scopes = nil,
        @auth_scheme : Symbol = :bearer,
        @enrolment_pending : Bool = false,
        mfa_verified : Bool? = nil,
        amr = [] of String,
        @acr : String? = nil,
        @auth_provider : String? = nil,
        @social_uid : String? = nil,
        @email : String? = nil,
        @email_verified : Bool = false,
        @key_id : String? = nil,
        @metadata : Hash(String, String) = {} of String => String,
        @claims : Hash(String, JSON::Any) = {} of String => JSON::Any,
        @validator : Proc(HTTP::Server::Context, Bool)? = nil,
      )
        @roles = roles.map(&.to_s).to_a
        perms = permissions.map(&.to_s).to_a
        if scopes
          scopes.each { |scope| perms << scope.to_s unless perms.includes?(scope.to_s) }
        end
        @permissions = perms
        @amr = amr.map(&.to_s).to_a
        @mfa_verified = mfa_verified.nil? ? Identity.infer_mfa_verified?(@amr, @acr) : mfa_verified
      end

      # Alias for `auth_provider`.
      def provider : String?
        @auth_provider
      end

      # Builds an `Identity` from verified JWT or OAuth 2.0 / Authly claims.
      #
      # Maps:
      # - `"sub"` (or `"id"`) -> `id`
      # - `"name"` (or `"preferred_username"`) -> `name`
      # - `"roles"` / `"role"` -> `roles`
      # - `"scope"` (space-delimited string), `"scopes"`, `"permissions"` -> `permissions` / `scopes`
      # - `"enrolment_pending"` -> `enrolment_pending?`
      # - `"mfa"` / `"mfa_verified"` / `"challenge_verified"`, `"amr"`, `"acr"` -> `mfa_verified?`, `amr`, `acr`
      # - `"provider"` / `"idp"` / `"cid": "social:<provider>"`, `"social_uid"`, `"email"`, `"email_verified"` -> social fields
      def self.from_claims(
        payload : Hash(String, JSON::Any),
        *,
        auth_scheme : Symbol = :bearer,
        validator : Proc(HTTP::Server::Context, Bool)? = nil,
      ) : Identity
        subject = payload["sub"]?.try(&.as_s?) || payload["id"]?.try(&.as_s?) || ""
        display_name = payload["name"]?.try(&.as_s?) || payload["preferred_username"]?.try(&.as_s?)
        extracted_roles = extract_string_list(payload["roles"]?) + extract_string_list(payload["role"]?)
        extracted_perms = extract_space_or_list(payload["scope"]?) +
                          extract_space_or_list(payload["scopes"]?) +
                          extract_string_list(payload["permissions"]?)
        pending = payload["enrolment_pending"]?.try(&.as_bool?) || false
        extracted_amr = (extract_string_list(payload["amr"]?) + extract_string_list(payload["grant_type"]?)).uniq
        extracted_acr = payload["acr"]?.try(&.as_s?)
        explicit_mfa = extract_explicit_mfa(payload)
        provider_name = extract_provider(payload)
        social_id = payload["social_uid"]?.try(&.as_s?)
        email_val = payload["email"]?.try(&.as_s?)
        email_ver = extract_bool(payload["email_verified"]?)
        kid = payload["key_id"]?.try(&.as_s?) || payload["kid"]?.try(&.as_s?)

        meta = build_metadata(payload, provider_name, social_id, kid)

        new(
          id: subject,
          name: display_name,
          roles: extracted_roles.uniq,
          permissions: extracted_perms.uniq,
          auth_scheme: auth_scheme,
          enrolment_pending: pending,
          mfa_verified: explicit_mfa,
          amr: extracted_amr,
          acr: extracted_acr,
          auth_provider: provider_name,
          social_uid: social_id,
          email: email_val,
          email_verified: email_ver,
          key_id: kid,
          metadata: meta,
          claims: payload,
          validator: validator
        )
      end

      protected def self.infer_mfa_verified?(amr : Array(String), acr : String?) : Bool
        return true if amr.any? { |entry| DEFAULT_MFA_AMR.includes?(entry.downcase) }
        return true if acr && DEFAULT_MFA_ACR.includes?(acr.downcase)
        false
      end

      private def self.extract_explicit_mfa(payload : Hash(String, JSON::Any)) : Bool?
        {"mfa", "mfa_verified", "challenge_verified"}.each do |key|
          if val = payload[key]?
            if !(flag = val.as_bool?).nil?
              return flag
            end
          end
        end
        nil
      end

      private def self.extract_provider(payload : Hash(String, JSON::Any)) : String?
        if explicit = payload["provider"]?.try(&.as_s?).presence || payload["idp"]?.try(&.as_s?).presence
          return explicit
        end
        if (cid = payload["cid"]?.try(&.as_s?)) && cid.starts_with?("social:")
          cid.lchop("social:").presence
        end
      end

      private def self.extract_bool(value : JSON::Any?) : Bool
        return false unless value
        case raw = value.raw
        when Bool   then raw
        when String then raw.downcase == "true"
        else             false
        end
      end

      private def self.build_metadata(
        payload : Hash(String, JSON::Any),
        provider : String?,
        social_uid : String?,
        key_id : String?,
      ) : Hash(String, String)
        meta = {} of String => String
        payload["cid"]?.try(&.as_s?).try { |cid| meta["client_id"] = cid }
        payload["jti"]?.try(&.as_s?).try { |jti| meta["jti"] = jti }
        meta["provider"] = provider if provider
        meta["social_uid"] = social_uid if social_uid
        meta["key_id"] = key_id if key_id
        meta
      end

      # Builds an `Identity` from an `Authly::Claims` (or any object exposing `#payload : Hash(String, JSON::Any)`).
      def self.from_claims(
        claims_obj,
        *,
        auth_scheme : Symbol = :bearer,
        validator : Proc(HTTP::Server::Context, Bool)? = nil,
      ) : Identity
        from_claims(claims_obj.payload, auth_scheme: auth_scheme, validator: validator)
      end

      # OAuth 2.0 client identifier (`"cid"` or `"client_id"` claim), if present.
      def client_id : String?
        @claims["cid"]?.try(&.as_s?) || @claims["client_id"]?.try(&.as_s?) || @metadata["client_id"]?
      end

      # Token identifier (`"jti"` claim), if present.
      def token_id : String?
        @claims["jti"]?.try(&.as_s?) || @metadata["jti"]?
      end

      def valid?(context : HTTP::Server::Context) : Bool
        @validator.try(&.call(context)) != false
      end

      private def self.extract_string_list(value : JSON::Any?) : Array(String)
        return [] of String unless value
        case raw = value.raw
        when String
          raw.split(/[\s,]+/, remove_empty: true)
        when Array
          raw.compact_map(&.as_s?)
        else
          [] of String
        end
      end

      private def self.extract_space_or_list(value : JSON::Any?) : Array(String)
        return [] of String unless value
        case raw = value.raw
        when String
          raw.split(' ', remove_empty: true)
        when Array
          raw.compact_map(&.as_s?)
        else
          [] of String
        end
      end
    end
  end
end

class HTTP::Server::Context
  # The authenticated principal for the current request, set by `Azu::Handler::Authentication`
  # (or bridged automatically from `context.authly_claims` when `Authly::Handler::Bearer` is used).
  @principal : Azu::Auth::Principal? = nil

  def principal=(@principal : Azu::Auth::Principal?) : Azu::Auth::Principal?
  end

  def principal : Azu::Auth::Principal?
    principal?
  end

  def principal? : Azu::Auth::Principal?
    if existing = @principal
      return existing
    end
    {% if @top_level.has_constant?("Authly") %}
      if claims = @authly_claims
        return @principal = Azu::Auth::Identity.from_claims(claims.payload)
      end
    {% end %}
    nil
  end

  def principal! : Azu::Auth::Principal
    principal? || raise Azu::Response::AuthenticationError.new
  end

  # Alias for `principal?`.
  def current_user : Azu::Auth::Principal?
    principal?
  end

  # Alias for `principal?`.
  def current_user? : Azu::Auth::Principal?
    principal?
  end

  # Alias for `principal!`.
  def current_user! : Azu::Auth::Principal
    principal!
  end

  def current_user=(user : Azu::Auth::Principal?) : Azu::Auth::Principal?
    @principal = user
  end
end
