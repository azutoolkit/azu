require "http"

module Azu
  # The seam between Azu and a session library. Azu does not depend on one: an app that has one
  # (for example the `session` shard with `require "session/azu"`) installs an adapter at boot and
  # the template helpers (`session`, `flash`) and `Handler::CSRF::SessionTokenStore` read through it.
  #
  # ```
  # Azu.session_adapter = Azu::SessionAdapter.new(
  #   flash: ->(context : HTTP::Server::Context) { context.flash.to_h },
  #   csrf_token: ->(context : HTTP::Server::Context) { context.session.csrf_token },
  #   store_csrf_token: ->(context : HTTP::Server::Context, token : String) { context.session.csrf_token = token; nil },
  # )
  # ```
  #
  # Every reader is optional; one that is not given answers empty (`nil` for the CSRF token). The two
  # CSRF procs go together: giving only one raises `ArgumentError`, because a token that can be read but
  # never stored (or the reverse) would make every request fail validation without saying why.
  #
  # The adapter belongs to a configuration (`Configuration#session_adapter`, per `Azu::App`);
  # `Azu.session_adapter=` sets it on the current one. Set it once at boot, before serving.
  struct SessionAdapter
    alias Values = Hash(String, String)

    class NotConfigured < Exception
      def initialize
        super("no session adapter with a CSRF token: set Azu.session_adapter (see Azu::SessionAdapter) before using the session CSRF token store")
      end
    end

    def initialize(
      @session : Proc(HTTP::Server::Context, Values)? = nil,
      @flash : Proc(HTTP::Server::Context, Values)? = nil,
      @csrf_token : Proc(HTTP::Server::Context, String?)? = nil,
      @store_csrf_token : Proc(HTTP::Server::Context, String, Nil)? = nil,
    )
      raise ArgumentError.new("csrf_token and store_csrf_token must be given together") unless @csrf_token.nil? == @store_csrf_token.nil?
    end

    # Whether the CSRF token can be read and stored through this adapter.
    def csrf? : Bool
      !@csrf_token.nil?
    end

    def session(context : HTTP::Server::Context) : Values
      @session.try(&.call(context)) || Values.new
    end

    def flash(context : HTTP::Server::Context) : Values
      @flash.try(&.call(context)) || Values.new
    end

    def csrf_token(context : HTTP::Server::Context) : String?
      @csrf_token.try(&.call(context))
    end

    def store_csrf_token(context : HTTP::Server::Context, token : String) : Nil
      @store_csrf_token.try(&.call(context, token))
    end
  end

  # The session adapter of the current configuration (`Azu.current_config`).
  def self.session_adapter : SessionAdapter?
    current_config.session_adapter
  end

  def self.session_adapter=(adapter : SessionAdapter?) : SessionAdapter?
    current_config.session_adapter = adapter
  end
end
