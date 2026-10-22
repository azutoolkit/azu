require "../../spec_helper"
require "../../../src/azu/migrations"

private alias SQL = Azu::Migrations::SQL

describe Azu::Migrations::SQL do
  describe ".ident" do
    it "quotes plain and schema-qualified names" do
      SQL.ident(:users).should eq %("users")
      SQL.ident("public.users").should eq %("public"."users")
    end

    it "rejects anything that is not a plain identifier" do
      ["users; DROP TABLE x", %(us"ers), "a.b.c", "1abc", "", "us ers"].each do |bad|
        expect_raises(Azu::Migrations::InvalidIdentifier) { SQL.ident(bad) }
      end
    end
  end

  describe ".literal" do
    it "renders values with quotes doubled" do
      SQL.literal("it's").should eq "'it''s'"
      SQL.literal(nil).should eq "NULL"
      SQL.literal(true).should eq "TRUE"
      SQL.literal(42).should eq "42"
      SQL.literal(1.5).should eq "1.5"
      SQL.literal(:member).should eq "'member'"
      SQL.literal(Time.utc(2026, 10, 22, 1, 2, 3)).should start_with "'2026-10-22 01:02:03"
      SQL.literal(JSON.parse(%({"a":"it's"}))).should eq %('{"a":"it''s"}')
    end
  end

  describe ".create_index" do
    it "builds the common forms" do
      SQL.create_index(:users, [:email]).should eq %(CREATE INDEX "index_users_on_email" ON "users" ("email"))
      SQL.create_index(:users, [:email], unique: true).should eq %(CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email"))
      SQL.create_index(:users, [:a, :b], name: "custom").should eq %(CREATE INDEX "custom" ON "users" ("a", "b"))
    end

    it "supports methods, partial and covering indexes, operator classes and expressions" do
      SQL.create_index(:docs, [:body], using: :gin).should eq %(CREATE INDEX "index_docs_on_body" ON "docs" USING gin ("body"))
      SQL.create_index(:docs, [:meta], using: :gin, opclass: "jsonb_path_ops").should contain %(("meta" jsonb_path_ops))
      SQL.create_index(:users, [:email], unique: true, where: "deleted_at IS NULL").should end_with %(WHERE deleted_at IS NULL)
      SQL.create_index(:users, [:email], covering: [:name]).should contain %(INCLUDE ("name"))
      SQL.create_index(:users, [] of Symbol | String, expression: "lower(email)", name: "users_lower_email").should eq %(CREATE INDEX "users_lower_email" ON "users" (lower(email)))
      SQL.create_index(:users, ["created_at DESC NULLS LAST"]).should contain %(("created_at" DESC NULLS LAST))
    end

    it "supports concurrent and idempotent creation" do
      SQL.create_index(:users, [:email], concurrent: true, if_not_exists: true).should start_with "CREATE INDEX CONCURRENTLY IF NOT EXISTS"
    end

    it "rejects unknown methods and unsafe columns" do
      expect_raises(ArgumentError, /unknown index method/) { SQL.create_index(:users, [:a], using: :nope) }
      expect_raises(Azu::Migrations::InvalidIdentifier) { SQL.create_index(:users, ["a); DROP TABLE users; --"]) }
      expect_raises(ArgumentError) { SQL.create_index(:users, [] of Symbol | String) }
    end

    it "keeps generated names within PostgreSQL's 63 byte limit" do
      columns = (1..8).map { |i| "a_rather_long_column_name_#{i}" }
      name = SQL.index_name(:users, columns)
      name.bytesize.should be <= 63
      name.should eq SQL.index_name(:users, columns)
      name.should_not eq SQL.index_name(:users, columns.reverse)
    end
  end

  it "builds DROP INDEX" do
    SQL.drop_index("idx", concurrent: true).should eq %(DROP INDEX CONCURRENTLY IF EXISTS "idx")
    SQL.drop_index("idx", if_exists: false).should eq %(DROP INDEX "idx")
  end

  it "maps referential actions" do
    SQL.action(:cascade).should eq "CASCADE"
    SQL.action("nullify").should eq "SET NULL"
    expect_raises(ArgumentError) { SQL.action(:explode) }
  end
end
