class Post < Azu::Model
  table :posts

  column id : Int64, primary_key: true
  column user_id : Int64
  column title : String
  column body : String = ""
  column status : String = "draft" # a PostgreSQL enum (post_status)
  column views : Int32 = 0
  timestamps
  soft_delete # delete! marks deleted_at, restore! brings it back, force_delete! removes the row

  validates :title, presence: true, length: 3..200

  belongs_to user : User
  has_many comments : Comment, foreign_key: :post_id

  scope :published, -> { where(status: "published") }
  scope :recent, -> { order(id: :desc) }
end
