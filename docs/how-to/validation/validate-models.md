# Validate models

This guide shows you how to add validation to your CQL database models. These rules belong to the model and protect the
database; validation of incoming HTTP data belongs to the request contract (see
[Validate Requests](validate-requests.md)). A request that passes its contract can still produce a model that fails
here, so both layers are useful.

Every example defines the schema and model it needs; in an application they live in their own files.

## Basic Model Validation

`validate` is a class-level macro: it takes the attribute name as a symbol, one or more rules, and an optional
`message:`. The rules run each time the record is validated:

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
  validate :email, presence: true, match: /@/
  validate :age, gt: 0, lt: 150

  def initialize(@name : String, @email : String, @age : Int32 = 18)
  end
end

user = User.new("A", "invalid", 200)
user.valid?                      # => false
user.errors.map(&.message)       # => ["name must have a size of 2..100", "email must match the pattern /@/", "age must be less than 150"]
```

Put all the rules of an attribute in one `validate` call: a second call for the same attribute replaces the first.

The rules are `presence`, `required`, `size`, `match`, `gt`, `gte`, `lt`, `lte`, `eq`, `in`, `exclude`,
`confirmation` and `accept`. Any other name (such as `length`, `format` or `numericality`) stops compilation with
`unsupported predicate`. The [validations reference](../../reference/database/validations.md) lists each rule.

## Validation Rules

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :articles do
    primary :id, Int64
    column :title, String
    column :slug, String
    column :handle, String
    column :code, String
    column :status, String
    column :quantity, Int32
    column :price, Float64
    column :terms, Bool, default: false
    column :password, String, null: true
  end
end

class Article
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :articles

  property title : String
  property slug : String
  property handle : String = "anonymous"
  property code : String
  property status : String
  property quantity : Int32
  property price : Float64
  property terms : Bool = false
  property password : String?

  @[DB::Field(ignore: true)]
  property password_confirmation : String?

  # Presence and size (a Range, or an exact Int)
  validate :title, presence: true, size: 5..200
  validate :code, size: 6

  # Format
  validate :slug, match: /\A[a-z0-9-]+\z/, message: "may only contain lowercase letters, digits and dashes"

  # Comparisons
  validate :quantity, gte: 0
  validate :price, gt: 0.0

  # Membership (an Array or a Range)
  validate :status, in: %w(draft published archived)
  validate :handle, exclude: %w(admin new edit)

  # Booleans and confirmation
  validate :terms, accept: true, message: "must be accepted"
  validate :password_confirmation, confirmation: :password

  def initialize(@title : String, @slug : String, @code : String, @status : String = "draft", @quantity : Int32 = 0, @price : Float64 = 1.0)
  end
end

Article.new("Hello world", "hello-world", "abc123").errors.size
```

Rules treat `nil` as invalid: `gt: 0` on an `Int32?` property that is `nil` fails, and `confirmation` fails unless both
the field and its confirmation are set. For an optional value write a custom validator (below) or give the property a
default instead of a rule. `presence` calls `empty?`, so it works on strings and collections but does not compile on
numbers; use `required: true` or a comparison for those.

## Custom Validators

Subclass `CQL::ActiveRecord::Validations::CustomValidator`, return the errors from `valid?`, and attach it with `use`.
This is the place for rules that need the database, such as uniqueness, or that involve several fields:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :email, String
    column :age, Int32, null: true
  end
end

class UniqueEmail < CQL::ActiveRecord::Validations::CustomValidator
  def initialize(@record : User)
  end

  def valid? : Array(CQL::ActiveRecord::Validations::Error)
    errors = [] of CQL::ActiveRecord::Validations::Error
    taken = User.where(email: @record.email).exists?
    errors << CQL::ActiveRecord::Validations::Error.new(:email, "has already been taken") if taken && @record.new_record?
    errors
  end
end

class AdultsOnly < CQL::ActiveRecord::Validations::CustomValidator
  def initialize(@record : User)
  end

  def valid? : Array(CQL::ActiveRecord::Validations::Error)
    errors = [] of CQL::ActiveRecord::Validations::Error
    if (age = @record.age) && age < 18
      errors << CQL::ActiveRecord::Validations::Error.new(:age, "must be at least 18")
    end
    errors
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property email : String
  property age : Int32?

  validate :email, required: true, match: /@/
  use UniqueEmail
  use AdultsOnly

  def initialize(@email : String, @age : Int32? = nil)
  end
end

User.new("alice@example.com", 17).errors.map(&.message)   # => ["must be at least 18"]
```

The uniqueness check above is racy: two requests can pass it at the same time. Back it with a `unique: true` column in the
schema and rescue the database error as the last line of defence.

## Validation Callbacks

`save` runs the `before_validation` callbacks, then the `after_validation` callbacks, and only then validates. Both
run before the validation, so an `after_validation` callback also runs for a record that is invalid; it can call
`errors`, which validates on demand. A callback that returns `false` stops the save:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  before_validation :normalize

  validate :email, match: /@/

  def initialize(@name : String, @email : String)
  end

  private def normalize
    @name = name.strip
    @email = email.strip.downcase
    true
  end
end

user = User.new("  Alice ", " ALICE@EXAMPLE.COM ")
user.save   # name and email are normalized before they are validated
```

`valid?` and `errors` do not run callbacks, so normalize before calling them yourself when you need to.

## Checking Validity

`valid?` returns a `Bool`, `errors` returns the failures as `CQL::ActiveRecord::Validations::Error` values (`field` and
`message`), and `validate!` raises `CQL::ActiveRecord::Validations::ValidationError`. `save` and `save!` validate first
and raise the same error when the record is invalid; they return `false` only when a callback halts the save:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  validate :name, presence: true
  validate :email, match: /@/

  def initialize(@name : String, @email : String)
  end
end

user = User.new("", "invalid")

if user.valid?
  user.save!
else
  user.errors.each { |error| puts "#{error.field}: #{error.message}" }
end

begin
  user.save!
rescue ex : CQL::ActiveRecord::Validations::ValidationError
  puts ex.message   # all messages, joined with ","
end
```

### In an Azu Endpoint

Turn the model's errors into Azu's `422` response so clients get the same shape as request-contract failures:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  validate :name, presence: true
  validate :email, match: /@/

  def initialize(@name : String, @email : String)
  end
end

def save_or_422(user : User) : User
  return user if user.save
  raise Azu::Response::ValidationError.new({"base" => ["could not be saved"]})
rescue ex : CQL::ActiveRecord::Validations::ValidationError
  fields = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
  user.errors.each { |error| fields[error.field.to_s] << error.message }
  raise Azu::Response::ValidationError.new(fields.to_h)
end

save_or_422(User.new("Alice", "alice@example.com"))
```

## Skipping Validations

Validation is only part of `save`/`save!` and the instance `create!`. These write straight to the database without
validating or running callbacks, so use them for trusted data only:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  validate :name, presence: true

  def initialize(@name : String, @email : String)
  end
end

User.create!(name: "", email: "x")          # class-level create!: no validation
user = User.find!(1_i64)
user.update!(name: "")                      # update!: no validation
User.update_by({:name => "".as(DB::Any)}, {:name => "Unnamed".as(DB::Any)})
```

## Validation Contexts

CQL's `validate` accepts an `on:` option meant to restrict a rule to a context, but in this release it does not
compile (`undefined macro variable 'context'`), so do not use it. Express "only on create" in a custom validator with
`@record.new_record?`, as the uniqueness validator above does.

## See Also

- [Validate Requests](validate-requests.md)
- [Handle Validation Errors](handle-validation-errors.md)
- [Validations Reference](../../reference/database/validations.md)
