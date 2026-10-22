require "../../spec_helper"
require "../../support/postgres"
require "../../../src/azu/database"

# Migrations register globally when defined, so these specs use their own versions and tables.
module MigratorSpec
  USERS      = 20260101000001_i64
  TYPES      = 20260101000002_i64
  CONCURRENT = 20260101000003_i64
  ALTERS     = 20260101000004_i64
  BROKEN     = 20260101000099_i64
  TABLE      = :mig_spec_schema_migrations

  class CreateUsers < Azu::Migration(20260101000001_i64)
    def up
      enable_extension :pgcrypto
      create_table :mig_users do |t|
        t.string :email
        t.text :bio, null: true
        t.jsonb :settings, default_sql: "'{}'::jsonb"
        t.array :tags, of: :text, default_sql: "'{}'"
        t.uuid :token, default_sql: "gen_random_uuid()"
        t.timestamps
        t.index :email, unique: true
        t.index :settings, using: :gin
        t.index :email, name: "mig_users_live_email", where: "bio IS NOT NULL"
      end
    end

    def down
      drop_table :mig_users
    end
  end

  class AddEnumAndPosts < Azu::Migration(20260101000002_i64)
    def up
      create_enum :mig_status, %w(active suspended)
      add_column :mig_users, :status, "mig_status", default: "active"
      create_table :mig_posts do |t|
        t.references :mig_user, on_delete: :cascade
        t.string :title
      end
    end

    def down
      drop_table :mig_posts
      remove_column :mig_users, :status
      drop_enum :mig_status
    end
  end

  class ConcurrentIndex < Azu::Migration(20260101000003_i64)
    disable_ddl_transaction!

    def up
      add_index :mig_posts, :title, concurrent: true
    end

    def down
      remove_index :mig_posts, :title, concurrent: true
    end
  end

  class Alterations < Azu::Migration(20260101000004_i64)
    def up
      add_column :mig_users, :age, :integer, null: true
      change_column_default :mig_users, :age, default: 18
      rename_column :mig_posts, :title, :headline
      add_check_constraint :mig_users, "age >= 0", name: "mig_users_age_positive", validate: false
      validate_check_constraint :mig_users, "mig_users_age_positive"
      add_foreign_key :mig_posts, :mig_users, column: :mig_user_id, name: "mig_posts_user_fk", validate: false
      validate_foreign_key :mig_posts, "mig_posts_user_fk"
    end

    def down
      remove_foreign_key :mig_posts, "mig_posts_user_fk"
      remove_check_constraint :mig_users, "mig_users_age_positive"
      rename_column :mig_posts, :headline, :title
      remove_column :mig_users, :age
    end
  end

  # Fails half way: nothing it did may survive and its version must not be recorded.
  class Broken < Azu::Migration(20260101000099_i64)
    def up
      create_table :mig_half_done { |t| t.string :name }
      execute "SELECT * FROM mig_does_not_exist"
    end

    def down
    end
  end

  # Limited to this spec's classes so migrations other specs define do not leak in.
  def self.migrator : Azu::Migrator
    Azu::Migrator.new(table: TABLE, migrations: [CreateUsers, AddEnumAndPosts, ConcurrentIndex, Alterations, Broken] of Azu::BaseMigration.class)
  end

  def self.scalar(sql : String)
    Azu::Database.schema.raw_readonly(sql, 1)[1].first?.try(&.first?)
  end

  def self.table?(name : String) : Bool
    scalar("SELECT to_regclass('#{name}') IS NOT NULL") == "true"
  end

  def self.index?(name : String) : Bool
    scalar("SELECT count(*) FROM pg_indexes WHERE indexname = '#{name}'") == "1"
  end

  def self.reset
    schema = Azu::Database.schema
    %w(mig_half_done mig_posts mig_users).each { |table| schema.exec("DROP TABLE IF EXISTS #{table} CASCADE") }
    schema.exec("DROP TYPE IF EXISTS mig_status")
    schema.exec("DROP TABLE IF EXISTS #{TABLE}")
  end
end

describe Azu::Migrator do
  before_all do
    if PostgresSpec.available?
      Azu::CONFIG.database.url = PostgresSpec.url
      Azu::Database.schema = nil
      Azu::Database.schema
    end
  end

  before_each { MigratorSpec.reset if PostgresSpec.available? }
  after_all { MigratorSpec.reset if PostgresSpec.available? }

  # Everything but the deliberately failing migration.
  last_good = MigratorSpec::ALTERS

  it "applies pending migrations in version order and records them" do
    PostgresSpec.require!
    ran = MigratorSpec.migrator.migrate(to: last_good)
    ran.map(&.version).should eq [MigratorSpec::USERS, MigratorSpec::TYPES, MigratorSpec::CONCURRENT, MigratorSpec::ALTERS]

    MigratorSpec.table?("mig_users").should be_true
    MigratorSpec.table?("mig_posts").should be_true
    MigratorSpec.index?("index_mig_users_on_email").should be_true
    MigratorSpec.index?("index_mig_users_on_settings").should be_true
    MigratorSpec.index?("mig_users_live_email").should be_true
    MigratorSpec.index?("index_mig_posts_on_headline").should be_false
    MigratorSpec.index?("index_mig_posts_on_title").should be_true # the renamed column keeps its index and the index keeps its name
    MigratorSpec.scalar("SELECT count(*) FROM #{MigratorSpec::TABLE}").should eq "4"
    MigratorSpec.migrator.current_version.should eq last_good
    MigratorSpec.migrator.pending.map(&.version).should eq [MigratorSpec::BROKEN]
  end

  it "uses PostgreSQL types" do
    PostgresSpec.require!
    MigratorSpec.migrator.migrate(to: last_good)
    types = Azu::Database.schema.raw_readonly(
      "SELECT column_name, data_type, udt_name FROM information_schema.columns WHERE table_name = 'mig_users' ORDER BY ordinal_position", 20)[1]
    by_column = types.to_h { |row| {row[0].to_s, row[1..]} }
    by_column["settings"].should eq ["jsonb", "jsonb"]
    by_column["tags"].should eq ["ARRAY", "_text"]
    by_column["token"].should eq ["uuid", "uuid"]
    by_column["status"].should eq ["USER-DEFINED", "mig_status"]
    by_column["created_at"].should eq ["timestamp with time zone", "timestamptz"]
  end

  it "builds the concurrent index outside a transaction" do
    PostgresSpec.require!
    MigratorSpec.migrator.migrate(to: MigratorSpec::CONCURRENT)
    MigratorSpec.index?("index_mig_posts_on_title").should be_true
  end

  it "is idempotent" do
    PostgresSpec.require!
    MigratorSpec.migrator.migrate(to: last_good)
    MigratorSpec.migrator.migrate(to: last_good).should be_empty
  end

  it "reports status including down migrations" do
    PostgresSpec.require!
    MigratorSpec.migrator.migrate(to: MigratorSpec::TYPES)
    status = MigratorSpec.migrator.status.select { |entry| entry.version < MigratorSpec::BROKEN }
    status.map(&.applied?).should eq [true, true, false, false]
    status.first.name.should eq "MigratorSpec::CreateUsers"
    status.first.applied_at.should_not be_nil
  end

  it "rolls back by steps, to a version, and redoes" do
    PostgresSpec.require!
    migrator = MigratorSpec.migrator
    migrator.migrate(to: last_good)

    migrator.rollback.map(&.version).should eq [MigratorSpec::ALTERS]
    MigratorSpec.scalar("SELECT count(*) FROM information_schema.columns WHERE table_name = 'mig_users' AND column_name = 'age'").should eq "0"

    migrator.rollback(2).map(&.version).should eq [MigratorSpec::CONCURRENT, MigratorSpec::TYPES]
    MigratorSpec.table?("mig_posts").should be_false
    MigratorSpec.table?("mig_users").should be_true

    migrator.redo.map(&.version).should eq [MigratorSpec::USERS]
    MigratorSpec.table?("mig_users").should be_true
    migrator.current_version.should eq MigratorSpec::USERS

    migrator.migrate(to: last_good)
    migrator.rollback_to(MigratorSpec::USERS).map(&.version).should eq [MigratorSpec::ALTERS, MigratorSpec::CONCURRENT, MigratorSpec::TYPES]
    migrator.rollback_to(0_i64).map(&.version).should eq [MigratorSpec::USERS]
    MigratorSpec.table?("mig_users").should be_false
  end

  it "rolls a failing migration back completely and names it in the error" do
    PostgresSpec.require!
    MigratorSpec.migrator.migrate(to: last_good)
    error = expect_raises(Azu::Migrations::MigrationError) { MigratorSpec.migrator.migrate }
    error.message.to_s.should contain "20260101000099"
    error.message.to_s.should contain "MigratorSpec::Broken"
    MigratorSpec.table?("mig_half_done").should be_false
    MigratorSpec.migrator.current_version.should eq last_good
  end

  it "dry-runs without touching the database" do
    PostgresSpec.require!
    migrator = MigratorSpec.migrator
    ran = migrator.migrate(to: MigratorSpec::USERS, dry_run: true)
    ran.map(&.version).should eq [MigratorSpec::USERS]
    migrator.statements.any?(&.starts_with?(%(CREATE TABLE "mig_users"))).should be_true
    migrator.statements.last.should contain "INSERT INTO"
    MigratorSpec.table?("mig_users").should be_false
    MigratorSpec.table?(MigratorSpec::TABLE.to_s).should be_false
  end

  it "serialises concurrent runs with an advisory lock" do
    PostgresSpec.require!
    DB.open(PostgresSpec.url) do |other|
      other.using_connection do |holder|
        holder.exec("SELECT pg_advisory_lock($1)", Azu::Migrator::LOCK_KEY)
        done = Channel(Nil).new
        spawn do
          MigratorSpec.migrator.migrate(to: MigratorSpec::USERS)
          done.send(nil)
        end

        select
        when done.receive
          fail "the migration ran while another session held the lock"
        when timeout(400.milliseconds)
        end
        MigratorSpec.table?("mig_users").should be_false

        holder.exec("SELECT pg_advisory_unlock($1)", Azu::Migrator::LOCK_KEY)
        select
        when done.receive
        when timeout(5.seconds)
          fail "the migration never ran after the lock was released"
        end
        MigratorSpec.table?("mig_users").should be_true
      end
    end
  end

  it "refuses a concurrent index inside a transaction" do
    executor = Azu::Migrations::Executor.new(nil, dry_run: true)
    executor.require_no_transaction!("CREATE INDEX CONCURRENTLY") # fine outside a transaction
    executor.in_transaction = true
    expect_raises(Azu::Migrations::MigrationError, /disable_ddl_transaction!/) { executor.require_no_transaction!("CREATE INDEX CONCURRENTLY") }
  end
end
