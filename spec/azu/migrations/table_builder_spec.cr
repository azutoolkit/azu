require "../../spec_helper"
require "../../../src/azu/migrations"

private def build(id : Symbol | Bool = :bigserial, &) : Array(String)
  builder = Azu::Migrations::TableBuilder.new(:posts, id)
  yield builder
  builder.statements
end

describe Azu::Migrations::TableBuilder do
  it "creates a table with a bigserial key by default" do
    build { |t| t.string :title }.first.should eq %(CREATE TABLE "posts" (\n  "id" BIGSERIAL PRIMARY KEY,\n  "title" character varying(255) NOT NULL\n))
  end

  it "supports other key types and none at all" do
    build(:uuid) { }.first.should contain %("id" UUID PRIMARY KEY DEFAULT gen_random_uuid())
    build(:serial) { }.first.should contain %("id" SERIAL PRIMARY KEY)
    build(false) { |t| t.integer :n }.first.should_not contain "PRIMARY KEY"
    expect_raises(ArgumentError) { build(:nope) { } }
  end

  it "defaults columns to NOT NULL and honours null, default, unique and check" do
    sql = build do |t|
      t.text :bio, null: true
      t.string :role, default: "member", limit: 20
      t.integer :age, null: true, check: "age >= 0"
      t.boolean :active, default: true
      t.string :email, unique: true
      t.datetime :seen_at, default_sql: "now()"
    end.first
    sql.should contain %("bio" text,)
    sql.should contain %("role" character varying(20) NOT NULL DEFAULT 'member')
    sql.should contain %("age" integer CHECK (age >= 0))
    sql.should contain %("active" boolean NOT NULL DEFAULT TRUE)
    sql.should contain %("email" character varying(255) NOT NULL UNIQUE)
    sql.should contain %("seen_at" timestamptz NOT NULL DEFAULT now())
  end

  it "knows PostgreSQL types: jsonb, uuid, arrays, enums, decimals, citext, inet" do
    sql = build do |t|
      t.jsonb :meta, default_sql: "'{}'::jsonb"
      t.uuid :token
      t.array :tags, of: :text
      t.enum_column :status, :post_status, default: "draft"
      t.decimal :price, precision: 10, scale: 2
      t.citext :handle
      t.inet :ip, null: true
    end.first
    sql.should contain %("meta" jsonb NOT NULL DEFAULT '{}'::jsonb)
    sql.should contain %("token" uuid NOT NULL)
    sql.should contain %("tags" text[] NOT NULL)
    sql.should contain %("status" post_status NOT NULL DEFAULT 'draft')
    sql.should contain %("price" numeric(10, 2) NOT NULL)
    sql.should contain %("handle" citext NOT NULL)
    sql.should contain %("ip" inet\n)
  end

  it "adds references with their foreign key and index" do
    statements = build { |t| t.references :user, on_delete: :cascade }
    statements.first.should contain %("user_id" bigint NOT NULL)
    statements.first.should contain %(FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE)
    statements.should contain %(CREATE INDEX "index_posts_on_user_id" ON "posts" ("user_id"))

    plain = build { |t| t.references :author, to: :people, foreign_key: false, index: false, null: true }
    plain.size.should eq 1
    plain.first.should contain %("author_id" bigint\n)
    plain.first.should_not contain "FOREIGN KEY"
  end

  it "adds timestamps, constraints and indexes" do
    statements = build do |t|
      t.timestamps
      t.soft_delete
      t.unique [:a, :b], name: "uniq_ab"
      t.check "a < b", name: "chk_ab"
      t.index :a, unique: true, where: "deleted_at IS NULL"
      t.index :b, using: :gin
    end
    statements.first.should contain %("created_at" timestamptz NOT NULL DEFAULT now())
    statements.first.should contain %("updated_at" timestamptz NOT NULL DEFAULT now())
    statements.first.should contain %("deleted_at" timestamptz,)
    statements.first.should contain %(CONSTRAINT "uniq_ab" UNIQUE ("a", "b"))
    statements.first.should contain %(CONSTRAINT "chk_ab" CHECK (a < b))
    statements[1].should eq %(CREATE UNIQUE INDEX "index_posts_on_a" ON "posts" ("a") WHERE deleted_at IS NULL)
    statements[2].should contain "USING gin"
  end

  it "raises for unknown or unsafe types and names" do
    expect_raises(ArgumentError, /unknown column type/) { build { |t| t.column :x, :nope } }
    expect_raises(ArgumentError, /invalid SQL type/) { build { |t| t.column :x, "text; drop table users" } }
    expect_raises(Azu::Migrations::InvalidIdentifier) { build { |t| t.string "bad name" } }
  end

  it "can create idempotently" do
    builder = Azu::Migrations::TableBuilder.new(:posts)
    builder.statements(if_not_exists: true).first.should start_with %(CREATE TABLE IF NOT EXISTS "posts")
  end
end
