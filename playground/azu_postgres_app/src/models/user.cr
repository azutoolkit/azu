class User < Azu::Model
  table :users

  column id : Int64, primary_key: true
  column email : String, validate: :email, unique: true
  column name : String
  column role : String = "member"
  column token : UUID = UUID.random
  column settings : JSON::Any = JSON.parse(%({"theme": "light"}))
  timestamps

  validates :name, presence: true, length: 2..80

  has_many posts : Post, foreign_key: :user_id
  has_many comments : Comment, foreign_key: :user_id

  scope :admins, -> { where(role: "admin") }
  scope :recent, -> { order(id: :desc) }
end
