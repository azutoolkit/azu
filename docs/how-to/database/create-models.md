# How to Create Models

This guide shows you how to create CQL models that map to your database tables.

## Basic Model

Create a model class:

```crystal
class User
  include CQL::Model(User, Int64)
  db_context AcmeDB, :users

  property id : Int64?
  property name : String
  property email : String
  property created_at : Time?
  property updated_at : Time?

  def initialize(@name = "", @email = "")
  end
end
```

## Model with Validations

```crystal
class User
  include CQL::Model(User, Int64)
  db_context AcmeDB, :users

  property id : Int64?
  property name : String
  property email : String
  property age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true, length: {min: 2, max: 100}
  validate email, presence: true, format: /@/, uniqueness: true
  validate age, numericality: {greater_than: 0}, allow_nil: true
end
```

## Associations

### Belongs To

```crystal
class Post
  include CQL::Model(Post, Int64)
  db_context AcmeDB, :posts

  property id : Int64?
  property user_id : Int64
  property title : String
  property content : String

  belongs_to :user, User, foreign_key: :user_id
end
```

### Has Many

```crystal
class User
  include CQL::Model(User, Int64)
  db_context AcmeDB, :users

  property id : Int64?
  property name : String
  property email : String

  has_many :posts, Post, foreign_key: :user_id
  has_many :comments, Comment, foreign_key: :user_id
end
```

### Has One

```crystal
class User
  include CQL::Model(User, Int64)
  db_context AcmeDB, :users

  property id : Int64?
  property name : String

  has_one :profile, Profile, foreign_key: :user_id
end
```

### Many to Many

```crystal
class Post
  include CQL::Model(Post, Int64)
  db_context AcmeDB, :posts

  property id : Int64?
  property title : String

  has_many :post_tags, PostTag, foreign_key: :post_id
  has_many :tags, Tag, through: :post_tags
end

class Tag
  include CQL::Model(Tag, Int64)
  db_context AcmeDB, :tags

  property id : Int64?
  property name : String

  has_many :post_tags, PostTag, foreign_key: :tag_id
  has_many :posts, Post, through: :post_tags
end

class PostTag
  include CQL::Model(PostTag, Int64)
  db_context AcmeDB, :post_tags

  property id : Int64?
  property post_id : Int64
  property tag_id : Int64

  belongs_to :post, Post
  belongs_to :tag, Tag
end
```

## Callbacks

```crystal
class User
  include CQL::Model(User, Int64)
  db_context AcmeDB, :users

  property id : Int64?
  property email : String
  property normalized_email : String?

  before_save :normalize_email
  after_create :send_welcome_email
  before_destroy :cleanup_associations

  private def normalize_email
    @normalized_email = email.downcase.strip
  end

  private def send_welcome_email
    Mailer.welcome(self).deliver
  end

  private def cleanup_associations
    posts.each(&.destroy)
  end
end
```

## Scopes

```crystal
class Post
  include CQL::Model(Post, Int64)
  db_context AcmeDB, :posts

  property id : Int64?
  property title : String
  property published : Bool
  property created_at : Time?

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }
end

# Usage
Post.published.recent.all
Post.by_user(user.id).published.all
```

## Custom Methods

```crystal
class User
  include CQL::Model(User, Int64)
  db_context AcmeDB, :users

  property id : Int64?
  property name : String
  property email : String
  property password_hash : String?

  def full_name
    name
  end

  def password=(plain_password : String)
    @password_hash = Crypto::Bcrypt::Password.create(plain_password).to_s
  end

  def authenticate(plain_password : String) : Bool
    return false unless hash = password_hash
    Crypto::Bcrypt::Password.new(hash).verify(plain_password)
  end

  def recent_posts(limit = 10)
    Post.where(user_id: id).order(created_at: :desc).limit(limit).all
  end
end
```

## JSON Serialization

```crystal
class User
  include CQL::Model(User, Int64)
  include JSON::Serializable
  db_context AcmeDB, :users

  property id : Int64?
  property name : String
  property email : String

  @[JSON::Field(ignore: true)]
  property password_hash : String?
end

# Serialize to JSON
user.to_json  # {"id": 1, "name": "Alice", "email": "alice@example.com"}
```

## See Also

- [Define Schema](define-schema.md)
- [Query Data](query-data.md)
