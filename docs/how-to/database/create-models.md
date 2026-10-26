# Create models

This guide shows you how to create CQL models that map to your database tables. A model is a class that includes
`CQL::ActiveRecord::Model(PrimaryKeyType)` and points at a table of a [schema](define-schema.md) with `db_context`.

Every example is self-contained: it defines the schema it needs first. In an application the schema lives in
`src/db/schema.cr` and the models `require` it.

## Basic Model

Declare one property per column. `DB::Serializable` fills the properties from the result set, so names and types must
match the table; nullable columns are `T?`:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32, null: true
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String
  property age : Int32?
  property created_at : Time?
  property updated_at : Time?

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

user = User.new("Alice", "alice@example.com")
user.save                  # runs validations and callbacks, then INSERTs
puts user.id               # => Int64? (nil until saved)
puts User.table            # => :users
```

The primary key (`id`) and `persisted?`/`new_record?` come from the module, so you do not declare `id`. Pass the key
type in the `include` (`Int64`, `Int32` or `UUID`); it must match the `primary` column of the table.
`created_at` and `updated_at` are filled in by `save`.

To check at boot that every property matches its column, run the app with `CQL_VALIDATE_SCHEMA_MAPPINGS=1`.

## Model with Validations

`validate` takes the attribute and one or more predicates; `message:` overrides the default message. The predicates
are `presence`, `required`, `size`, `match`, `gt`, `gte`, `lt`, `lte`, `eq`, `in`, `exclude`, `confirmation` and
`accept` (see the [validations reference](../../reference/database/validations.md)):

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :age, Int32
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String
  property age : Int32

  validate :name, presence: true, size: 2..100
  validate :email, presence: true, match: /@/, message: "must be an email address"
  validate :age, gt: 0, lt: 150

  def initialize(@name : String, @email : String, @age : Int32 = 18)
  end
end

user = User.new("A", "nope")
user.valid?                          # => false
user.errors.map(&.message)           # => ["name must have a size of 2..100", "must be an email address"]
```

There is no uniqueness validation; enforce it with a `unique: true` column and rescue the database error, or check
with `User.exists?(email: email)` in a [custom validator](../validation/validate-models.md#custom-validators).

## Associations

`has_many`, `belongs_to` and `has_one` name the foreign key explicitly. The foreign key must be a typed property of
the model that holds it (`belongs_to` and `has_one`/`has_many` fail to compile with a message naming the missing
property otherwise):

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
  end

  table :profiles do
    primary :id, Int64
    column :user_id, Int64
    column :bio, String
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String

  belongs_to :user, User, :user_id

  def initialize(@user_id : Int64, @title : String)
  end
end

class Profile
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :profiles

  property user_id : Int64
  property bio : String

  def initialize(@user_id : Int64, @bio : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String

  has_many :posts, Post, foreign_key: :user_id
  has_one :profile, Profile, foreign_key: :user_id

  def initialize(@name : String)
  end
end

user = User.find!(1_i64)
user.posts.to_a                      # => Array(Post), loaded lazily
user.posts.where(title: "Hello").all(Post)
user.profile                         # => Profile?
Post.find!(1_i64).user               # => User? (belongs_to is optional unless you pass optional: false)
```

Pass `foreign_key:` on `has_many` and `has_one`: without it CQL guesses `<model_name>_id` from the class name.
`dependent:` is accepted (`:destroy`, `:delete_all`, `:nullify`, `:restrict_with_error` for `has_many`) but
`delete!` does not apply it, so children are not removed with their parent. Declare `on_delete: :cascade` on the
foreign key in the [schema](define-schema.md) and let the database do it (SQLite only enforces foreign keys when
`PRAGMA foreign_keys = ON`). `preload` only works for `has_many`.

### Many to Many

`many_to_many` goes through a join model:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :posts do
    primary :id, Int64
    column :title, String
  end

  table :tags do
    primary :id, Int64
    column :name, String
  end

  table :post_tags do
    primary :id, Int64
    column :post_id, Int64
    column :tag_id, Int64
  end
end

class PostTag
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :post_tags

  property post_id : Int64
  property tag_id : Int64

  def initialize(@post_id : Int64, @tag_id : Int64)
  end
end

class Tag
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :tags

  property name : String

  many_to_many :posts, Post, join_through: PostTag, foreign_key: :tag_id, association_foreign_key: :post_id

  def initialize(@name : String)
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property title : String

  many_to_many :tags, Tag, join_through: PostTag, foreign_key: :post_id, association_foreign_key: :tag_id

  def initialize(@title : String)
  end
end

post = Post.find!(1_i64)
post.tags.to_a                       # => Array(Tag)
post.tags_ids                        # => Array(Int64)
post.tags_count                      # => Int64
```

## Callbacks

The callbacks are `before_validation`, `after_validation`, `before_save`, `after_save`, `before_create`,
`after_create`, `before_update`, `after_update`, `before_destroy` and `after_destroy`. Each takes the name of a method;
a method that returns `false` stops the operation:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :email, String
    column :normalized_email, String, null: true
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property email : String
  property normalized_email : String?

  before_save :normalize_email
  after_create :log_creation

  def initialize(@email : String)
  end

  private def normalize_email
    @normalized_email = email.downcase.strip
    true
  end

  private def log_creation
    Log.info { "created user #{id}" }
    true
  end
end

user = User.new(" Alice@Example.com ")
user.save
puts user.normalized_email           # => "alice@example.com"
```

Callbacks run for `save` (instance) and `delete!`. `User.create!(...)` and `update!` write directly and skip both
validations and callbacks; use `User.new(...).save` when you need them.

## Scopes

`scope` defines a named query on the class. A scope can take arguments and scopes chain with each other and with
`where`, `order`, `limit`:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :published, Bool, default: false
    timestamps
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property created_at : Time?

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }

  def initialize(@user_id : Int64, @title : String)
  end
end

Post.published.recent.all
Post.by_user(1_i64).published.limit(5).all
```

## Custom Methods

Add behaviour with ordinary methods. Properties that are not columns need `@[DB::Field(ignore: true)]`:

```crystal
require "cql"
require "sqlite3"
require "crypto/bcrypt/password"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :password_hash, String, null: true
  end

  table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :created_at, Time, null: true
  end
end

class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String
  property created_at : Time?

  def initialize(@user_id : Int64, @title : String)
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property password_hash : String?

  @[DB::Field(ignore: true)]
  property remember_me : Bool = false

  def initialize(@name : String)
  end

  def password=(plain_password : String)
    @password_hash = Crypto::Bcrypt::Password.create(plain_password).to_s
  end

  def authenticate(plain_password : String) : Bool
    return false unless hash = password_hash
    Crypto::Bcrypt::Password.new(hash).verify(plain_password)
  end

  def recent_posts(limit : Int32 = 10) : Array(Post)
    Post.where(user_id: id!).order(created_at: :desc).limit(limit).all
  end
end

user = User.new("Alice")
user.password = "secret"
user.authenticate("secret")
user.recent_posts(3)
```

## JSON Serialization

Include `JSON::Serializable` next to the model and ignore sensitive fields:

```crystal
require "cql"
require "sqlite3"
require "json"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :password_hash, String, null: true
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  include JSON::Serializable
  db_context AcmeDB, :users

  property name : String
  property email : String

  @[JSON::Field(ignore: true)]
  property password_hash : String?

  def initialize(@name : String, @email : String)
  end
end

User.new("Alice", "alice@example.com").to_json
```

Inside an Azu endpoint you usually return a response object built from the model instead of serializing the model
directly; see [Working with Databases](../../tutorials/working-with-databases.md).

## See Also

- [Define Schema](define-schema.md)
- [Query Data](query-data.md)
- [Validate Models](../validation/validate-models.md)
