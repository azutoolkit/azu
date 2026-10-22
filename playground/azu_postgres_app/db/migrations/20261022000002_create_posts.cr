class CreatePosts < Azu::Migration(20261022000002_i64)
  def up
    create_enum :post_status, %w(draft published archived)

    create_table :posts do |t|
      t.references :user, on_delete: :cascade
      t.string :title
      t.text :body, default: ""
      t.enum_column :status, :post_status, default: "draft"
      t.integer :views, default: 0
      t.timestamps
      t.soft_delete

      # Partial index: only live, published posts are listed on the front page.
      t.index :created_at, name: "index_posts_published_on_created_at", where: "status = 'published' AND deleted_at IS NULL"
    end
  end

  def down
    drop_table :posts
    drop_enum :post_status
  end
end
