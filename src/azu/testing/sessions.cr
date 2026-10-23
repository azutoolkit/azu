require "random/secure"

module Azu
  module Testing
    # An in-memory `Azu::SessionAdapter`: sessions live in a hash keyed by the id in the `COOKIE` cookie, so
    # `Client#login_with` can start one without a session library, and the CSRF `SessionTokenStore` works.
    # A client carries its own cookie, so two clients never share a session.
    class Sessions
      COOKIE     = "_azu_test_session"
      CSRF_FIELD = "_csrf"

      @@registry = {} of Configuration => Sessions
      @@mutex = Mutex.new

      # The store behind *config*'s session adapter, installing the adapter first. Every `acquire` must be
      # matched by a `release`; the adapter is removed from the configuration with the last one. Refuses an
      # adapter this class did not install.
      def self.acquire(config : Configuration) : Sessions
        @@mutex.synchronize do
          sessions = @@registry[config]? || begin
            raise ArgumentError.new("the app already has a session adapter; log in through its own endpoints") if config.session_adapter
            new.tap { |created| config.session_adapter = created.adapter; @@registry[config] = created }
          end
          sessions.tap(&.retain)
        end
      end

      def self.release(config : Configuration) : Nil
        @@mutex.synchronize do
          sessions = @@registry[config]? || return
          return unless sessions.drop.zero?
          @@registry.delete(config)
          config.session_adapter = nil
        end
      end

      def initialize
        @data = {} of String => SessionAdapter::Values
        @mutex = Mutex.new
        @users = 0
      end

      protected def retain : Int32
        @users += 1
      end

      protected def drop : Int32
        @users -= 1
      end

      # Starts a session holding *values* and returns its id.
      def start(values : SessionAdapter::Values = SessionAdapter::Values.new) : String
        id = Random::Secure.urlsafe_base64(24)
        @mutex.synchronize { @data[id] = values }
        id
      end

      def [](id : String) : SessionAdapter::Values?
        @mutex.synchronize { @data[id]? }
      end

      def adapter : SessionAdapter
        SessionAdapter.new(
          session: ->(context : HTTP::Server::Context) { find(context) || SessionAdapter::Values.new },
          csrf_token: ->(context : HTTP::Server::Context) { find(context).try(&.[CSRF_FIELD]?) },
          store_csrf_token: ->(context : HTTP::Server::Context, token : String) { (find(context) || begin_for(context))[CSRF_FIELD] = token; nil },
        )
      end

      private def find(context : HTTP::Server::Context) : SessionAdapter::Values?
        id = context.request.cookies[COOKIE]?.try(&.value) || context.response.cookies[COOKIE]?.try(&.value)
        id.try { |key| self[key] }
      end

      private def begin_for(context : HTTP::Server::Context) : SessionAdapter::Values
        values = SessionAdapter::Values.new
        id = start(values)
        context.response.cookies << HTTP::Cookie.new(COOKIE, id, path: "/", http_only: true)
        values
      end
    end
  end
end
