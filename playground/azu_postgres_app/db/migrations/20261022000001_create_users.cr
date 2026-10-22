class CreateUsers < Azu::Migration(20261022000001_i64)
  def up
    enable_extension :pgcrypto

    create_table :users do |t|
      t.string :email
      t.string :name
      t.string :role, default: "member"
      t.uuid :token, default_sql: "gen_random_uuid()"
      t.jsonb :settings, default_sql: "'{}'::jsonb"
      t.timestamps

      t.index :email, unique: true
      t.index :settings, using: :gin
    end
  end

  def down
    drop_table :users
  end
end
