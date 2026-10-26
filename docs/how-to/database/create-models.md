---
description: Create CQL models that map to your database tables.
---

# Create models

A model is a class that includes `CQL::ActiveRecord::Model(PrimaryKeyType)` and points at a table of the
[schema](define-schema.md) with `db_context`.

Before you start: a project made by `azu new`, which configures CQL in `src/initializers/cql_config.cr` and declares
the tables in `src/db/schema.cr`. `azu generate model User name:string email:string:unique 'age:int32?'` writes
`src/models/user.cr`, adds the `users` table to the schema and writes the migration that creates it
(see [Run migrations](run-migrations.md)).

## The model

The examples on this page use this setup, laid out in the files `azu new` and `azu generate model` write. Each later
example reopens a class to add to it:

<!-- prelude -->
```crystal
# src/initializers/cql_config.cr
require "sqlite3"
require "azu/cql"

Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "sqlite3://./db/acme.db"
end

# src/db/schema.cr
AcmeDB = Azu::CQL.schema :acme do
  table :users do
    primary :id, Int64
    text :name
    text :email, unique: true
    column :age, Int32, null: true
    text :password_hash, null: true
    timestamps
  end

  table :posts do
    primary :id, Int64
    bigint :user_id
    text :title
    boolean :published, default: false
    timestamps

    foreign_key :user_id, references: :users, on_delete: :cascade
  end

  table :profiles do
    primary :id, Int64
    bigint :user_id
    text :bio
  end

  table :tags do
    primary :id, Int64
    text :name
  end

  table :post_tags do
    primary :id, Int64
    bigint :post_id
    bigint :tag_id
  end
end

# src/models/user.cr
class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String
  property age : Int32?
  property password_hash : String?
  property created_at : Time?
  property updated_at : Time?

  def initialize(@name : String, @email : String, @age : Int32? = nil)
  end
end

# src/models/post.cr
class Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :posts

  property user_id : Int64
  property title : String
  property published : Bool = false
  property created_at : Time?
  property updated_at : Time?

  def initialize(@user_id : Int64, @title : String)
  end
end
```

Declare one property per column. `DB::Serializable` fills the properties from the result set, so names and types must
match the table; nullable columns are `T?`. The primary key (`id`) and `persisted?`/`new_record?` come from the
module, so you do not declare `id`. Pass the key type in the `include` (`Int64`, `Int32` or `UUID`); it must match the
`primary` column of the table. `created_at` and `updated_at` are filled in by `save`:

```crystal
user = User.new("Alice", "alice@example.com")
user.save                  # runs validations and callbacks, then INSERTs
user.id                    # => 1
User.table                 # => :users
```

To check at boot that every property matches its column, run the app with `CQL_VALIDATE_SCHEMA_MAPPINGS=1`.

## Model with validations

Model rules protect the table. Checks on incoming HTTP data belong to the request contract (see
[Validate requests](../validation/validate-requests.md)); a request that passes its contract can still build a record
that fails here, so keep both.

`validate` takes the attribute and one or more predicates; `message:` overrides the default message. The predicates
are `presence`, `required`, `size`, `match`, `gt`, `gte`, `lt`, `lte`, `eq`, `in`, `exclude`, `confirmation` and
`accept` (see the [validations reference](../../reference/database/validations.md)):

```crystal
class User
  validate :name, presence: true, size: 2..100
  validate :email, presence: true, match: /@/, message: "must be an email address"
  validate :age, gt: 0, lt: 150
end

user = User.new("A", "nope", 30)
user.valid?                          # => false
user.errors.map(&.message)           # => ["name must have a size of 2..100", "must be an email address"]
```

A predicate fails for `nil`, so `validate :age, gt: 0` also rejects a user without an age.

### Check uniqueness and answer 422

There is no uniqueness rule. Check it in a
[custom validator](../../reference/database/validations.md#custom-validators) attached with `use`. `valid_or_422!`
(from `azu/cql`) runs the validations and returns the record, or raises `Azu::Response::ValidationError`, which the
`Rescuer` renders as the same `422` a request-contract failure gets:

```crystal
class UniqueEmail < CQL::ActiveRecord::Validations::CustomValidator
  def initialize(@record : User)
  end

  def valid? : Array(CQL::ActiveRecord::Validations::Error)
    errors = [] of CQL::ActiveRecord::Validations::Error
    if @record.new_record? && User.exists?(email: @record.email)
      errors << CQL::ActiveRecord::Validations::Error.new(:email, "has already been taken")
    end
    errors
  end
end

class User
  use UniqueEmail
end

User.new("Alice", "alice@example.com").valid_or_422!.save!

begin
  User.new("Alice", "alice@example.com").valid_or_422!
rescue ex : Azu::Response::ValidationError
  ex.status_code                     # => 422
  ex.field_errors                    # => {"email" => ["has already been taken"]}
end
```

`save` and `save!` raise `CQL::ActiveRecord::Validations::ValidationError` for an invalid record; `save` returns
`false` only when a callback halts it.

{% hint style="warning" %}
The uniqueness check races: two requests can pass it at the same time, so the `unique: true` column is the last line
of defence; rescue the database error it raises as well.
{% endhint %}

## Associations

`has_many`, `belongs_to` and `has_one` name the foreign key explicitly. The foreign key must be a typed property of
the model that holds it (`belongs_to` and `has_one`/`has_many` fail to compile with a message naming the missing
property otherwise):

```crystal
# src/models/profile.cr
class Profile
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :profiles

  property user_id : Int64
  property bio : String

  def initialize(@user_id : Int64, @bio : String)
  end
end

class User
  has_many :posts, Post, foreign_key: :user_id
  has_one :profile, Profile, foreign_key: :user_id
end

class Post
  belongs_to :user, User, :user_id
end

user = User.find!(1_i64)
user.posts.to_a                      # => Array(Post), loaded lazily
user.posts.where(title: "Hello").all(Post)
user.profile                         # => Profile?
Post.find!(1_i64).user               # => User? (belongs_to is optional unless you pass optional: false)
```

Pass `foreign_key:` on `has_many` and `has_one`: without it CQL guesses `<model_name>_id` from the class name.
`dependent:` (`:destroy`, `:delete_all`, `:nullify`, `:restrict_with_error` for `has_many`; `:destroy`, `:delete`,
`:nullify` for `has_one`) is applied by `delete!`, in the same transaction as the parent's own delete. An
`on_delete: :cascade` foreign key in the [schema](define-schema.md) also covers rows deleted with plain SQL; SQLite
enforces it because `Azu::CQL.schema` opens SQLite connections with `foreign_keys` on. `preload` works for
`has_many`, `has_one` and `belongs_to`.

### Many to many

`many_to_many` goes through a join model:

```crystal
# src/models/post_tag.cr
class PostTag
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :post_tags

  property post_id : Int64
  property tag_id : Int64

  def initialize(@post_id : Int64, @tag_id : Int64)
  end
end

# src/models/tag.cr
class Tag
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :tags

  property name : String

  many_to_many :posts, Post, join_through: PostTag, foreign_key: :tag_id, association_foreign_key: :post_id

  def initialize(@name : String)
  end
end

class Post
  many_to_many :tags, Tag, join_through: PostTag, foreign_key: :post_id, association_foreign_key: :tag_id
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
class User
  before_save :normalize_email
  after_create :log_creation

  private def normalize_email
    @email = email.downcase.strip
    true
  end

  private def log_creation
    Log.info { "created user #{id}" }
    true
  end
end

user = User.new("Alice", " Alice@Example.com ")
user.save
user.email                           # => "alice@example.com"
```

Callbacks run for `save` (instance) and `delete!`.

{% hint style="warning" %}
`User.create!(...)` and `update!` write directly and skip both validations and callbacks; use `User.new(...).save`
when you need them.
{% endhint %}

To normalize values before they are validated, use `before_validation`; the
[validation lifecycle](../../reference/database/validations.md#validation-lifecycle) gives the order.

## Scopes

`scope` defines a named query on the class. A scope can take arguments and scopes chain with each other and with
`where`, `order`, `limit`:

```crystal
class Post
  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id : Int64) { where(user_id: user_id) }
end

Post.published.recent.all
Post.by_user(1_i64).published.limit(5).all
```

## Custom methods

Add behaviour with ordinary methods. Properties that are not columns need `@[DB::Field(ignore: true)]`:

```crystal
require "crypto/bcrypt/password"

class User
  @[DB::Field(ignore: true)]
  property remember_me : Bool = false

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

user = User.new("Alice", "alice@example.com")
user.password = "secret"
user.save
user.authenticate("secret")          # => true
user.recent_posts(3)
```

## JSON serialization

Include `JSON::Serializable` in the model and ignore sensitive fields:

```crystal
class User
  include JSON::Serializable

  @[JSON::Field(ignore: true)]
  property password_hash : String?
end

User.new("Alice", "alice@example.com").to_json
# => {"destroyed":false,"name":"Alice","email":"alice@example.com"}
```

`nil` fields are left out, and the model's own `destroyed` flag is included. An Azu endpoint usually returns a
response object built from the model instead; `Azu::CQL::FromModel` builds it from the model's fields (see
[CQL bridge](../../reference/api/cql-bridge.md#model-to-response)).

## See also

- [Define a schema](define-schema.md)
- [Query data](query-data.md)
- [Database validations](../../reference/database/validations.md)
- [CQL bridge](../../reference/api/cql-bridge.md)
