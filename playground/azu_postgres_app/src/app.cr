# Azu + CQL + PostgreSQL blog API.
#
#   export DATABASE_URL=postgres://postgres:postgres@localhost:5432/azu_blog_development
#   crystal run db/tasks.cr -- setup     # create + migrate + seed
#   crystal run src/app.cr               # http://localhost:4000, dashboard at /__dev
#
# DATABASE_URL is the only configuration: the pool, the schema and the dev dashboard's
# Database tab are wired up by `require "azu/database"`.
require "pg"
require "azu"
require "azu/database"
require "./models"

module BlogApp
  include Azu

  configure do |c|
    c.port = (ENV["PORT"]? || "4000").to_i
    c.env = Azu::Environment::Development
    c.database.n_plus_one = Azu::DatabaseConfiguration::NPlusOne::Warn # log lazy loads inside loops
    c.database.slow_query_ms = 50
  end
end

require "./api"

BlogApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::DevDashboard.new("/__dev"),
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
