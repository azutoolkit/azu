require "../../src/azu"
require "sqlite3"
require "db"

module ExampleApp
  # Simple record types for query results
  record UserRow, id : Int64, name : String, email : String
  record PostRow, id : Int64, user_id : Int64, title : String

  # In-memory SQLite database using plain DB
  DATABASE = DB.open("sqlite3::memory:")

  # Initialize the database tables
  def self.init_database
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL

    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    SQL

    # Seed some test data
    5.times do |i|
      DATABASE.exec(
        "INSERT INTO users (name, email) VALUES (?, ?)",
        "User #{i + 1}", "user#{i + 1}@example.com"
      )

      3.times do |j|
        DATABASE.exec(
          "INSERT INTO posts (user_id, title, body) VALUES (?, ?, ?)",
          (i + 1).to_i64, "Post #{j + 1} by User #{i + 1}", "This is the body of post #{j + 1}"
        )
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

  # Endpoint that executes REAL database queries
  struct RealDatabaseEndpoint
    include Azu::Endpoint(RealDatabaseRequest, RealDatabaseResponse)

    get "/real-db"

    def call : RealDatabaseResponse
      query_type = real_database_request.query_type

      case query_type
      when "test"
        RealDatabaseResponse.new("Test endpoint working!", {"status" => "ok"}.to_json)
      when "all_users"
        users = [] of UserRow
        DATABASE.query("SELECT id, name, email FROM users") do |rs|
          rs.each do
            users << UserRow.new(
              id: rs.read(Int64),
              name: rs.read(String),
              email: rs.read(String)
            )
          end
        end
        user_data = users.map { |u| {"id" => u.id, "name" => u.name, "email" => u.email} }
        RealDatabaseResponse.new("Fetched #{users.size} users", user_data.to_json)
      when "all_posts"
        posts = [] of PostRow
        DATABASE.query("SELECT id, user_id, title FROM posts") do |rs|
          rs.each do
            posts << PostRow.new(
              id: rs.read(Int64),
              user_id: rs.read(Int64),
              title: rs.read(String)
            )
          end
        end
        post_data = posts.map { |p| {"id" => p.id, "user_id" => p.user_id, "title" => p.title} }
        RealDatabaseResponse.new("Fetched #{posts.size} posts", post_data.to_json)
      when "n_plus_one"
        users = [] of UserRow
        DATABASE.query("SELECT id, name, email FROM users") do |rs|
          rs.each do
            users << UserRow.new(
              id: rs.read(Int64),
              name: rs.read(String),
              email: rs.read(String)
            )
          end
        end

        results = users.map do |user|
          post_count = DATABASE.scalar("SELECT COUNT(*) FROM posts WHERE user_id = ?", user.id).as(Int64).to_i
          {"user" => user.name, "post_count" => post_count}
        end
        RealDatabaseResponse.new(
          "Executed N+1 pattern: 1 + #{users.size} queries",
          results.to_json
        )
      when "join"
        result = DATABASE.exec(<<-SQL)
          SELECT users.name, COUNT(posts.id) as post_count
          FROM users
          LEFT JOIN posts ON users.id = posts.user_id
          GROUP BY users.id, users.name
        SQL
        RealDatabaseResponse.new("Executed JOIN query", {"rows_affected" => result.rows_affected}.to_json)
      when "insert"
        timestamp = Time.utc.to_unix
        DATABASE.exec(
          "INSERT INTO users (name, email) VALUES (?, ?)",
          "New User #{timestamp}", "new#{timestamp}@example.com"
        )
        RealDatabaseResponse.new("Inserted new user", {"success" => true}.to_json)
      when "slow"
        result = DATABASE.exec(<<-SQL)
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
        query_type = params["query"]? || "all_users"
        RealDatabaseRequest.new(query_type)
      end
    end
  end
end
