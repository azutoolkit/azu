require "./initializers/cql_config"

# Plain CQL models: nothing Azu-specific.
class Post
  include ::CQL::ActiveRecord::Model(Int64)
  db_context schema: AppDB, table: :posts

  property user_id : Int64
  property title : String
  property body : String

  belongs_to :user, User, :user_id

  def initialize(@user_id, @title, @body)
  end
end

class User
  include ::CQL::ActiveRecord::Model(Int64)
  db_context schema: AppDB, table: :users

  property name : String
  property email : String

  has_many :posts, Post, foreign_key: :user_id

  def initialize(@name, @email)
  end
end
