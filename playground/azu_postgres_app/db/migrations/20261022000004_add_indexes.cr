# Indexes on tables that are already serving traffic are built CONCURRENTLY (no write lock),
# which PostgreSQL only allows outside a transaction.
class AddIndexes < Azu::Migration(20261022000004_i64)
  disable_ddl_transaction!

  def up
    add_index :comments, [:post_id, :created_at], concurrent: true
    add_index :posts, [] of Symbol | String, expression: "to_tsvector('english', title || ' ' || body)", using: :gin,
      name: "index_posts_on_search", concurrent: true
  end

  def down
    remove_index :posts, name: "index_posts_on_search", concurrent: true
    remove_index :comments, [:post_id, :created_at], concurrent: true
  end
end
