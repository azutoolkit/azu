# The only Azu <-> CQL wiring an app needs. One file, one block.
#
# Everything after this (models, queries, transactions, migrations) is plain CQL.
# Every query, transaction and the pool then show up in the dev dashboard's Database tab,
# tagged with the HTTP request that ran them.
require "pg"
require "../../../src/azu/cql" # in an app: require "azu/cql"

# DATABASE_URL, e.g. postgres://postgres@localhost:5432/azu_cql_demo
AppDB = Azu::CQL.schema :app, ENV["DATABASE_URL"]? || "postgres://localhost/azu_cql_demo" do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    timestamps
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :body, String
    timestamps
  end
end
