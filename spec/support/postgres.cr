require "pg"
require "./ci_pending"

# Specs that need a real PostgreSQL server (`AZU_TEST_PG_URL`, or `AZU_TEST_DATABASE_URL`, default
# postgres://localhost/azu_test). Without one they are reported as pending.
module PostgresSpec
  @@available : Bool? = nil

  def self.url : String
    ENV["AZU_TEST_PG_URL"]? || ENV["AZU_TEST_DATABASE_URL"]? || "postgres://localhost/azu_test"
  end

  def self.available? : Bool
    @@available ||= begin
      DB.open(url) { |db| db.scalar("SELECT 1") }
      true
    rescue
      false
    end
  end

  # Call at the top of an example: marks it pending when Postgres is unreachable.
  macro require!
    CIPending.skip!("postgres", "PostgreSQL not reachable at #{PostgresSpec.url}") unless PostgresSpec.available?
  end
end
