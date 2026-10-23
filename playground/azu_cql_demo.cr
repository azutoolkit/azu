# Azu + CQL demo: live SQL tracing in the dev dashboard.
#
#   cd playground && shards install
#   crystal run azu_cql_demo.cr
#   open http://localhost:4000/__dev   (Database & Queries tab)
#
# Everything runs on a local SQLite file: no database server needed.
require "../src/azu"
require "../src/azu/dev"
require "../src/azu/cql" # opt-in bridge: CQL queries -> dev dashboard
require "sqlite3"

module CqlDemo
  include Azu

  configure do |c|
    c.port = 4000
    c.env = Azu::Environment::Development
  end

  # Zero-config: instruments CQL, attaches the pool/SQL playground to the dashboard.
  DemoDB = Azu::CQL.schema(:cql_demo, "sqlite3://#{File.join(__DIR__, "azu_cql_demo.db")}") do
    table :users do
      primary :id, Int64
      column :name, String
      column :email, String
    end

    table :posts do
      primary :id, Int64
      column :user_id, Int64
      column :title, String
      column :body, String
    end
  end

  class Post
    include ::CQL::ActiveRecord::Model(Int64)
    db_context schema: DemoDB, table: :posts

    property user_id : Int64
    property title : String
    property body : String

    belongs_to :user, CqlDemo::User, :user_id

    def initialize(@user_id, @title, @body)
    end
  end

  class User
    include ::CQL::ActiveRecord::Model(Int64)
    db_context schema: DemoDB, table: :users

    property name : String
    property email : String

    has_many :posts, CqlDemo::Post, foreign_key: :user_id

    def initialize(@name, @email)
    end
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
    DemoDB.exec("DROP TABLE IF EXISTS posts")
    DemoDB.exec("DROP TABLE IF EXISTS users")
    DemoDB.build
    5.times do |i|
      user = User.create!(name: "User #{i + 1}", email: "user#{i + 1}@example.com")
      3.times { |j| Post.create!(user_id: user.id.not_nil!, title: "Post #{j + 1} by #{user.name}", body: "Lorem ipsum") }
    end
  end

  # GET /users - one query for users + one batched query for posts (no N+1)
  struct UsersEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/users"

    def call : JsonOut
      content_type "application/json"
      users = User.preload(:posts).all
      JsonOut.new(users.map { |user| {id: user.id, name: user.name, posts: user.posts.size} }.to_json)
    end
  end

  # GET /users/n_plus_one - deliberate N+1: one posts query per user
  struct NPlusOneEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/users/n_plus_one"

    def call : JsonOut
      content_type "application/json"
      users = User.all
      JsonOut.new(users.map { |user| {id: user.id, name: user.name, posts: Post.where(user_id: user.id.not_nil!).all.size} }.to_json)
    end
  end

  # POST /users?name=Ada&email=ada@example.com - CRUD insert
  struct CreateUserEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    post "/users"

    def call : JsonOut
      content_type "application/json"
      name = params["name"]? || "New User"
      user = User.create!(name: name, email: params["email"]? || "#{name.downcase.gsub(' ', '.')}@example.com")
      JsonOut.new({id: user.id, name: user.name}.to_json)
    end
  end

  # DELETE /users/:id
  struct DeleteUserEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    delete "/users/:id"

    def call : JsonOut
      content_type "application/json"
      user = User.find?(params.path["id"].to_i64)
      user.try(&.delete!)
      JsonOut.new({deleted: !user.nil?}.to_json)
    end
  end

  # POST /transfer?commit=true|false - transaction that commits or rolls back
  struct TransferEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    post "/transfer"

    def call : JsonOut
      content_type "application/json"
      commit = params["commit"]? != "false"
      Azu::CQL.transaction(DemoDB) do
        user = User.create!(name: "Transient", email: "transient#{Random.rand(100_000)}@example.com")
        Post.create!(user_id: user.id.not_nil!, title: "Created in a transaction", body: "...")
        raise DB::Rollback.new unless commit
      end
      JsonOut.new({committed: commit}.to_json)
    end
  end

  # GET /slow - a CPU heavy query that shows up red in the dashboard
  struct SlowEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/slow"

    def call : JsonOut
      content_type "application/json"
      DemoDB.exec("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1500000) SELECT count(*) FROM c")
      JsonOut.new({slow: true}.to_json)
    end
  end

  struct IndexEndpoint
    include Azu::Endpoint(NoParams, JsonOut)
    get "/"

    def call : JsonOut
      content_type "application/json"
      JsonOut.new({
        dashboard: "/__dev",
        try:       ["GET /users", "GET /users/n_plus_one", "POST /users?name=Ada", "POST /transfer?commit=false", "GET /slow"],
      }.to_json)
    end
  end
end

CqlDemo.seed
puts "Azu + CQL demo on http://localhost:4000  |  dashboard: http://localhost:4000/__dev"

CqlDemo.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::DevDashboard.new("/__dev"),
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
