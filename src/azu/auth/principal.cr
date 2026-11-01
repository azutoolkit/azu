require "http/server"

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

      # Fine-grained permissions granted to this principal (e.g. `["queues:read", "queues:write"]`).
      def permissions : Enumerable(String)
        [] of String
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
    end

    # Concrete, ready-to-use `Principal` for bearer tokens, JWT claims, or session users.
    class Identity < Principal
      getter id : String
      getter name : String?
      getter roles : Array(String)
      getter permissions : Array(String)
      getter auth_scheme : Symbol
      getter? enrolment_pending : Bool
      getter metadata : Hash(String, String)
      @validator : Proc(HTTP::Server::Context, Bool)?

      def initialize(
        @id : String,
        @name : String? = nil,
        roles = [] of String,
        permissions = [] of String,
        @auth_scheme : Symbol = :bearer,
        @enrolment_pending : Bool = false,
        @metadata : Hash(String, String) = {} of String => String,
        @validator : Proc(HTTP::Server::Context, Bool)? = nil,
      )
        @roles = roles.map(&.to_s).to_a
        @permissions = permissions.map(&.to_s).to_a
      end

      def valid?(context : HTTP::Server::Context) : Bool
        @validator.try(&.call(context)) != false
      end
    end
  end
end

class HTTP::Server::Context
  # The authenticated principal for the current request, set by `Azu::Handler::Authentication`
  # (or a custom authentication handler).
  property principal : Azu::Auth::Principal? = nil

  def principal? : Azu::Auth::Principal?
    @principal
  end

  def principal! : Azu::Auth::Principal
    @principal || raise Azu::Response::AuthenticationError.new
  end

  # Alias for `principal?`.
  def current_user : Azu::Auth::Principal?
    @principal
  end

  # Alias for `principal?`.
  def current_user? : Azu::Auth::Principal?
    @principal
  end

  # Alias for `principal!`.
  def current_user! : Azu::Auth::Principal
    principal!
  end

  def current_user=(user : Azu::Auth::Principal?) : Azu::Auth::Principal?
    @principal = user
  end
end
