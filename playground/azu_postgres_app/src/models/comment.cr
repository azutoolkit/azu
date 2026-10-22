class Comment < Azu::Model
  table :comments

  column id : Int64, primary_key: true
  column post_id : Int64
  column user_id : Int64
  column body : String
  timestamps

  validates :body, presence: true

  belongs_to post : Post
  belongs_to user : User
end
