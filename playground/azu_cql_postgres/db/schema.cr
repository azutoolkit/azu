# URL, adapter and pool come from CQL.configure (initializers/cql_config.cr).
AppDB = Azu::CQL.schema :app do
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
