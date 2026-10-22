class CreateComments < Azu::Migration(20261022000003_i64)
  def up
    create_table :comments do |t|
      t.references :post, on_delete: :cascade
      t.references :user, on_delete: :cascade
      t.text :body
      t.timestamps
    end
  end

  def down
    drop_table :comments
  end
end
