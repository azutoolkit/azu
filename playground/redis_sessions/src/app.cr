require "azu"
require "session/azu"

module RedisSessionsExample
  class State < Session::Base
    property visits : Int32 = 0
    property csrf_token : String? = nil
  end

  class_property csrf : Azu::Handler::CSRF?
  class_property pool : Session::ConnectionPool?
end

Session::Web.use_store(Session::RedisStore(RedisSessionsExample::State))

module RedisSessionsExample
  struct Routes
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.content_type = "application/json"
      case context.request.path
      when "/csrf"
        context.response.print({csrf: RedisSessionsExample.csrf.not_nil!.token(context)}.to_json)
      when "/session"
        context.response.print({visits: context.session.visits}.to_json)
      when "/visits"
        context.session.visits += 1
        context.response.status_code = 201
        context.response.print({visits: context.session.visits}.to_json)
      when "/failure"
        raise "example endpoint failure"
      end
      context
    end
  end

  # One store per application process, with a leased Redis connection per operation.
  def self.build
    pool = Session::ConnectionPool.new(Session::ConnectionPoolConfig.new(
      size: 20,
      timeout: 1.second,
      redis_host: ENV.fetch("REDIS_HOST", "127.0.0.1"),
      redis_port: ENV.fetch("REDIS_PORT", "6379").to_i,
      redis_database: ENV.fetch("REDIS_DATABASE", "0").to_i,
      redis_password: ENV["REDIS_PASSWORD"]?,
    ))
    self.pool = pool
    Session.configure do |config|
      config.secret = Azu::Env.secret("SESSION_SECRET")
      config.encrypt_redis_data = true
      config.cookie_secure = true
      config.store = Session::RedisStore(State).with_pool(pool)
    end

    app = Azu::App.new
    app.config.session_adapter = Azu::SessionAdapter.new(
      csrf_token: ->(context : HTTP::Server::Context) { context.session.csrf_token },
      store_csrf_token: ->(context : HTTP::Server::Context, token : String) { context.session.csrf_token = token; nil },
    )
    csrf = Azu::Handler::CSRF.new(
      strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken,
      token_store: Azu::Handler::CSRF::SessionTokenStore.new,
    )
    self.csrf = csrf
    app.routes do
      get "/csrf", Routes
      get "/session", Routes
      post "/visits", Routes
      get "/failure", Routes
    end
    handlers = app.default_handlers([
      Session::SessionHandler(State).new(Session.session),
      # Render errors before SessionHandler releases the request's session fiber.
      Azu::Handler::Rescuer.new,
      csrf,
    ] of HTTP::Handler)
    {app, handlers}
  end
end

{% unless flag?(:session_spec) %}
  app, handlers = RedisSessionsExample.build
  Azu.on_shutdown { RedisSessionsExample.pool.try(&.shutdown) }
  app.start(handlers)
{% end %}
