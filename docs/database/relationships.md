# Relationships

CQL supports four types of associations between models: `belongs_to`, `has_one`, `has_many`, and `many_to_many`.

## belongs_to

A model belongs to another model through a foreign key:

```crystal
struct Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  getter id : Int64?
  getter title : String
  getter user_id : Int64

  belongs_to :user, User, foreign_key: :user_id
end

# Usage
post = Post.find(1)
author = post.user  # Fetches associated user
```

## has_one

A model has exactly one associated record:

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String

  has_one :profile, UserProfile, foreign_key: :user_id
end

struct UserProfile
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :user_profiles

  getter id : Int64?
  getter user_id : Int64
  getter bio : String
  getter avatar_url : String?

  belongs_to :user, User, foreign_key: :user_id
end

# Usage
user = User.find(1)
profile = user.profile  # Fetches associated profile
```

## has_many

A model has multiple associated records:

```crystal
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String

  has_many :posts, Post, foreign_key: :user_id
  has_many :comments, Comment, foreign_key: :user_id
end

# Usage
user = User.find(1)
posts = user.posts      # Returns array of posts
count = user.posts.size # Count of posts
```

## many_to_many

Models related through a join table:

```crystal
struct Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  getter id : Int64?
  getter title : String

  many_to_many :tags, Tag, join_through: :post_tags
end

struct Tag
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :tags

  getter id : Int64?
  getter name : String

  many_to_many :posts, Post, join_through: :post_tags
end

# Join table schema
table :post_tags do
  primary :id, Int64
  bigint :post_id
  bigint :tag_id
  timestamps

  index [:post_id, :tag_id], unique: true
end

# Usage
post = Post.find(1)
tags = post.tags        # Returns array of tags

tag = Tag.find(1)
posts = tag.posts       # Returns array of posts
```

## Eager Loading

Prevent N+1 queries by preloading associations:

```crystal
# N+1 problem (bad)
posts = Post.all
posts.each do |post|
  puts post.user.name  # Executes query for each post
end

# Eager loading (good)
posts = Post.preload(:user).all
posts.each do |post|
  puts post.user.name  # No additional queries
end

# Multiple associations
posts = Post.preload(:user, :tags, :comments).all
```

## Nested Eager Loading

Load nested associations:

```crystal
# Load posts with users and their profiles
posts = Post.preload(user: :profile).all

# Access nested data without additional queries
posts.each do |post|
  puts "#{post.title} by #{post.user.name}"
  puts "Bio: #{post.user.profile.bio}"
end
```

## Association Queries

Query through associations:

```crystal
# Find user's published posts
user = User.find(1)
published = user.posts.where(published: true).all

# Find posts with specific tags
posts = Post.joins(:tags).where(tags: { name: "crystal" }).all

# Count associations
user = User.find(1)
post_count = user.posts.count
```

## Creating Associated Records

```crystal
# Through the association
user = User.find(1)
post = user.posts.create!(title: "New Post", content: "...")

# With explicit foreign key
post = Post.create!(
  title: "New Post",
  content: "...",
  user_id: user.id
)
```

## Complete Example

```crystal
# Schema
AppDB = CQL::Schema.define(:blog, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :users do
    primary :id, Int64
    text :name
    text :email
    timestamps
  end

  table :posts do
    primary :id, Int64
    text :title
    text :content
    bigint :user_id
    timestamps
    index :user_id
  end

  table :comments do
    primary :id, Int64
    text :body
    bigint :post_id
    bigint :user_id
    timestamps
    index :post_id
    index :user_id
  end
end

# Models
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String

  has_many :posts, Post, foreign_key: :user_id
  has_many :comments, Comment, foreign_key: :user_id
end

struct Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  getter id : Int64?
  getter title : String
  getter content : String
  getter user_id : Int64

  belongs_to :user, User, foreign_key: :user_id
  has_many :comments, Comment, foreign_key: :post_id
end

struct Comment
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :comments

  getter id : Int64?
  getter body : String
  getter post_id : Int64
  getter user_id : Int64

  belongs_to :post, Post, foreign_key: :post_id
  belongs_to :user, User, foreign_key: :user_id
end

# Usage in endpoint
struct PostEndpoint
  include Azu::Endpoint(EmptyRequest, PostResponse)

  get "/posts/:id"

  def call : PostResponse
    post = Post.preload(:user, :comments).find(params["id"].to_i64)
    PostResponse.new(post)
  end
end
```

## Next Steps

- [Queries](queries.md) - Build complex database queries
- [Performance](performance.md) - Optimize queries and prevent N+1
