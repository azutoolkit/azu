# Azu + CQL on PostgreSQL, wired by initializers/cql_config.cr.
#
#   createdb azu_cql_demo   # or set DATABASE_URL
#   crystal run playground/azu_cql_postgres/app.cr
#   open http://localhost:4000/__dev#database
require "../../src/azu"
require "./initializers/**" # configures CQL and attaches the dashboard (same order as an azu_cli project)
require "./db/**"           # the schema
require "./models"

module PostgresDemo
  include Azu

  configure do |c|
    c.port = 4000
    c.env = Azu::Environment::Development
    c.database.slow_query_ms = 50 # statements over this are logged and flagged in the dashboard
  end

  struct NoParams
    include Azu::Request
  end

  struct JsonOut
    include Azu::Response

    def initialize(@json : String)
    end

    def render
      @json
    end
  end

  def self.seed
    AppDB.exec("DROP TABLE IF EXISTS posts")
    AppDB.exec("DROP TABLE IF EXISTS users")
    AppDB.build
    5.times do |i|
      user = create_user("User #{i + 1}", "user#{i + 1}@example.com")
      3.times { |j| create_post(user, "Post #{j + 1} by #{user.name}") }
    end
  end

  def self.create_user(name : String, email : String) : User
    User.create!(name: name, email: email)
  end

  def self.create_post(user : User, title : String, body : String = "Lorem ipsum") : Post
    Post.create!(user_id: user.id.not_nil!, title: title, body: body)
  end

  # GET /users: one query for users + one batched query for posts
  struct UsersEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/users"

    def call : JsonOut
      content_type "application/json"
      JsonOut.new(User.preload(:posts).all.map { |user| {id: user.id, name: user.name, posts: user.posts.size} }.to_json)
    end
  end

  # GET /users/n_plus_one: deliberate N+1, one posts query per user (flagged in the dashboard)
  struct NPlusOneEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/users/n_plus_one"

    def call : JsonOut
      content_type "application/json"
      JsonOut.new(User.all.map { |user| {id: user.id, name: user.name, posts: Post.where(user_id: user.id.not_nil!).all.size} }.to_json)
    end
  end

  # POST /users?name=Ada
  struct CreateUserEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    post "/users"

    def call : JsonOut
      content_type "application/json"
      name = params["name"]? || "New User"
      user = PostgresDemo.create_user(name, "#{name.downcase.gsub(' ', '.')}.#{Random.rand(100_000)}@example.com")
      JsonOut.new({id: user.id, name: user.name}.to_json)
    end
  end

  # POST /transfer?commit=false: a transaction that commits or rolls back
  struct TransferEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    post "/transfer"

    def call : JsonOut
      content_type "application/json"
      commit = params["commit"]? != "false"
      Azu::CQL.transaction(AppDB) do
        user = PostgresDemo.create_user("Transient", "transient#{Random.rand(100_000)}@example.com")
        PostgresDemo.create_post(user, "Created in a transaction", "...")
        raise DB::Rollback.new unless commit
      end
      JsonOut.new({committed: commit}.to_json)
    end
  end

  # GET /slow: shows up red in the dashboard and as a log warning
  struct SlowEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/slow"

    def call : JsonOut
      content_type "application/json"
      AppDB.exec("SELECT pg_sleep(0.2)")
      JsonOut.new({slow: true}.to_json)
    end
  end

  struct IndexEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/"

    def call : JsonOut
      content_type "application/json"
      JsonOut.new({dashboard: "/__dev#database", try: ["GET /users", "GET /users/n_plus_one", "POST /users?name=Ada", "POST /transfer?commit=false", "GET /slow"]}.to_json)
    end
  end
end

PostgresDemo.seed unless ENV["SKIP_SEED"]? # SKIP_SEED=1 keeps the data (and boots without a database)

PostgresDemo.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::DevDashboard.new("/__dev"),
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
