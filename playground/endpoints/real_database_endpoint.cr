require "../../src/azu"
require "sqlite3"

module ExampleApp
  # Simple record types for query results
  record UserRow, id : Int64, name : String, email : String
  record PostRow, id : Int64, user_id : Int64, title : String

  # In-memory SQLite database schema using CQL
  DB_SCHEMA = CQL::Schema.define(:example_db, "sqlite3::memory:", CQL::Adapter::SQLite) do
    table :users do
      primary :id, Int64
      column :name, String
      column :email, String
      column :created_at, Time, default: "CURRENT_TIMESTAMP"
    end

    table :posts do
      primary :id, Int64
      column :user_id, Int64
      column :title, String
      column :body, String
      column :created_at, Time, default: "CURRENT_TIMESTAMP"
    end
  end

  # Initialize the database tables
  def self.init_database
    DB_SCHEMA.build

    # Seed some test data
    5.times do |i|
      DB_SCHEMA.insert.into(:users)
        .values(name: "User #{i + 1}", email: "user#{i + 1}@example.com")
        .commit

      3.times do |j|
        DB_SCHEMA.insert.into(:posts)
          .values(
            user_id: (i + 1).to_i64,
            title: "Post #{j + 1} by User #{i + 1}",
            body: "This is the body of post #{j + 1}"
          )
          .commit
      end
    end
  end

  # Request for real database queries
  struct RealDatabaseRequest
    include Azu::Request

    getter query_type : String = "all_users"

    def initialize(@query_type = "all_users")
    end

    def self.from_query(query_string : String) : RealDatabaseRequest
      params = HTTP::Params.parse(query_string)
      new(params.fetch("query", "all_users"))
    end

    def self.from_json(json : String) : RealDatabaseRequest
      data = JSON.parse(json)
      new(data["query"]?.try(&.as_s) || "all_users")
    end
  end

  struct RealDatabaseResponse
    include Azu::Response

    def initialize(@message : String, @data : String = "{}")
    end

    def render
      {message: @message, data: JSON.parse(@data)}.to_json
    end
  end

  # Simple test endpoint to verify file is being compiled
  struct RealDbTestEndpoint
    include Azu::Endpoint(RealDatabaseRequest, RealDatabaseResponse)

    get "/real-db-test"

    def call : RealDatabaseResponse
      RealDatabaseResponse.new("RealDbTestEndpoint is working - file compiled correctly!", {"version" => "2"}.to_json)
    end
  end

  # Endpoint that executes REAL database queries through CQL
  # All queries go through CQL::Performance.benchmark() automatically
  struct RealDatabaseEndpoint
    include Azu::Endpoint(RealDatabaseRequest, RealDatabaseResponse)

    get "/real-db"

    def call : RealDatabaseResponse
      query_type = real_database_request.query_type

      STDERR.puts ">>> RealDatabaseEndpoint received query_type: #{query_type}"
      STDOUT.flush
      STDERR.flush

      case query_type
      when "test"
        RealDatabaseResponse.new("Test endpoint working!", {"status" => "ok"}.to_json)
      when "all_users"
        # Simple SELECT query - metrics are recorded via CQL::Performance.after_query
        sql = "SELECT id, name, email FROM users"
        users = [] of UserRow
        start_time = Time.monotonic
        DB_SCHEMA.exec_query do |conn|
          conn.query(sql) do |result_set|
            result_set.each do
              users << UserRow.new(
                id: result_set.read(Int64),
                name: result_set.read(String),
                email: result_set.read(String)
              )
            end
          end
        end
        CQL::Performance.after_query(sql, [] of DB::Any, Time.monotonic - start_time, users.size.to_i64)
        user_data = users.map { |u| {"id" => u.id, "name" => u.name, "email" => u.email} }
        RealDatabaseResponse.new("Fetched #{users.size} users", user_data.to_json)
      when "all_posts"
        # Simple SELECT query on posts
        sql = "SELECT id, user_id, title FROM posts"
        posts = [] of PostRow
        start_time = Time.monotonic
        DB_SCHEMA.exec_query do |conn|
          conn.query(sql) do |result_set|
            result_set.each do
              posts << PostRow.new(
                id: result_set.read(Int64),
                user_id: result_set.read(Int64),
                title: result_set.read(String)
              )
            end
          end
        end
        CQL::Performance.after_query(sql, [] of DB::Any, Time.monotonic - start_time, posts.size.to_i64)
        post_data = posts.map { |p| {"id" => p.id, "user_id" => p.user_id, "title" => p.title} }
        RealDatabaseResponse.new("Fetched #{posts.size} posts", post_data.to_json)
      when "n_plus_one"
        # Demonstrates N+1 query pattern (bad practice, but useful for testing detection)
        sql_users = "SELECT id, name, email FROM users"
        users = [] of UserRow
        start_time = Time.monotonic
        DB_SCHEMA.exec_query do |conn|
          conn.query(sql_users) do |result_set|
            result_set.each do
              users << UserRow.new(
                id: result_set.read(Int64),
                name: result_set.read(String),
                email: result_set.read(String)
              )
            end
          end
        end
        CQL::Performance.after_query(sql_users, [] of DB::Any, Time.monotonic - start_time, users.size.to_i64)

        results = users.map do |user|
          sql_posts = "SELECT COUNT(*) FROM posts WHERE user_id = ?"
          post_count = 0
          post_start = Time.monotonic
          DB_SCHEMA.exec_query do |conn|
            post_count = conn.scalar(sql_posts, user.id).as(Int64).to_i
          end
          CQL::Performance.after_query(sql_posts, [user.id] of DB::Any, Time.monotonic - post_start, 1_i64)
          {"user" => user.name, "post_count" => post_count}
        end
        RealDatabaseResponse.new(
          "Executed N+1 pattern: 1 + #{users.size} queries",
          results.to_json
        )
      when "join"
        # Join query (more efficient than N+1)
        result = DB_SCHEMA.exec(<<-SQL)
          SELECT users.name, COUNT(posts.id) as post_count
          FROM users
          LEFT JOIN posts ON users.id = posts.user_id
          GROUP BY users.id, users.name
        SQL
        RealDatabaseResponse.new("Executed JOIN query", {"rows_affected" => result.rows_affected}.to_json)
      when "insert"
        # Insert a new user
        timestamp = Time.utc.to_unix
        DB_SCHEMA.insert.into(:users)
          .values(name: "New User #{timestamp}", email: "new#{timestamp}@example.com")
          .commit
        RealDatabaseResponse.new("Inserted new user", {"success" => true}.to_json)
      when "slow"
        # Simulate a slow query using SQLite's sleep-like behavior
        # Note: SQLite doesn't have a SLEEP function, so we use a recursive CTE
        result = DB_SCHEMA.exec(<<-SQL)
          WITH RECURSIVE cnt(x) AS (
            SELECT 1
            UNION ALL
            SELECT x+1 FROM cnt WHERE x < 100000
          )
          SELECT COUNT(*) FROM cnt;
        SQL
        RealDatabaseResponse.new("Executed slow query", {"rows_affected" => result.rows_affected}.to_json)
      else
        RealDatabaseResponse.new(
          "Available queries: all_users, all_posts, n_plus_one, join, insert, slow",
          ({} of String => String).to_json
        )
      end
    end

    private def real_database_request : RealDatabaseRequest
      if json = params.json
        RealDatabaseRequest.from_json(json)
      else
        # Use params["query"] directly instead of parsing the query string
        query_type = params["query"]? || "all_users"
        RealDatabaseRequest.new(query_type)
      end
    end
  end
end
