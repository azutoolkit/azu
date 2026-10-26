# Database validations

Reference for CQL model validations (`CQL::ActiveRecord::Validations`). For validating HTTP input see the
[Request Reference](../api/request.md); the two systems are independent.

## Validation Macro

### validate

Declares the rules for one attribute. The attribute is a symbol naming a readable property or getter of the model;
a typo stops compilation with `unknown attribute`:

```text
validate :attribute, rule: expected, ..., message: "text"
```

Calling `validate` again for the same attribute replaces the earlier call, so put all rules for an attribute in one
call. Rules are evaluated in the order written. A rule that fails adds one `Error` with the default message below, or with
`message:` when given (one custom message is used for every rule of that call).

An unknown rule name stops compilation: `unsupported predicate ... Supported predicates: eq, exclude, gt, gte, in, lt, lte,
match, size, presence, required, confirmation, accept.`

## Validation Rules

| Rule | Passes when | Default message |
| --- | --- | --- |
| `presence: true` | value is not `nil` and not empty (`String`, `Array`, `Hash`) | `<attr> must be present` |
| `required: true` | value is not `nil` | `<attr> is required` |
| `size: 2..50` / `size: 6` | `value.size` is in the range / equals the integer | `<attr> must have a size of <expected>` |
| `match: /re/` | the string matches the regular expression | `<attr> must match the pattern <expected>` |
| `eq: x` | `value == x` | `<attr> must be equal to <x>` |
| `gt: n`, `gte: n`, `lt: n`, `lte: n` | numeric (or `Time`) comparison | `<attr> must be greater than <n>`, ... |
| `in: [...]` / `in: 1..10` | the value is in the array or range | `<attr> must be included in <expected>` |
| `exclude: [...]` | the value is not in the array or range | `<attr> must not be included in <expected>` |
| `accept: true` | the value is `true`, `"true"`, `"1"`, `"on"` or `"yes"` (`accept: ["a", "b"]` for a custom set) | `<attr> must be accepted` |
| `confirmation: :other` | the value equals the property `other` (both set) | `<attr> confirmation doesn't match` |

The `in` and `exclude` messages print the Crystal literal as written, so an array of strings reads
`status must be included in ["active", "archived"] of ::String`; pass `message:` for user-facing text.

A `nil` value fails every rule. `presence` calls `empty?`, so it does not compile on numbers.
There is no `length`, `format`, `numericality`, `inclusion`, `exclusion`, `uniqueness`, `allow_nil`, `allow_blank`,
`if`/`unless`, and the `on:` option does not compile in this release; see
[Custom Validators](#custom-validators) for how to express those.

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :accounts do
    primary :id, Int64
    column :name, String
    column :slug, String
    column :email, String
    column :code, String
    column :age, Int32
    column :score, Float64
    column :role, String
    column :username, String
    column :terms, Bool, default: false
    column :password, String, null: true
  end
end

class Account
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :accounts

  property name : String
  property slug : String
  property email : String
  property code : String
  property age : Int32
  property score : Float64
  property role : String
  property username : String
  property terms : Bool = false
  property password : String?

  @[DB::Field(ignore: true)]
  property password_confirmation : String?

  # presence, size (Range or exact), match
  validate :name, presence: true, size: 2..100
  validate :code, size: 6
  validate :email, match: /\A[^@\s]+@[^@\s]+\z/, message: "is not an email address"
  validate :slug, match: /\A[a-z0-9-]+\z/

  # gt, gte, lt, lte, eq
  validate :age, gte: 18, lt: 150
  validate :score, gt: 0.0, lte: 100.0

  # in, exclude
  validate :role, in: %w(user admin moderator)
  validate :username, exclude: %w(admin root system)

  # accept, confirmation, required
  validate :terms, accept: true
  validate :password, required: true
  validate :password_confirmation, confirmation: :password

  def initialize(@name : String, @slug : String, @email : String, @code : String, @age : Int32, @score : Float64, @role : String, @username : String)
  end
end

account = Account.new("Al", "al", "al@example.com", "abc123", 30, 5.0, "user", "al")
account.valid?   # => false (terms not accepted, password missing)
```

## Custom Messages

`message:` replaces the default text for every rule in the same `validate` call. Split the rules over separate calls to
give each its own message:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :people do
    primary :id, Int64
    column :email, String
    column :age, Int32
  end
end

class Person
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :people

  property email : String
  property age : Int32

  validate :email, required: true, message: "is required for registration"
  validate :age, gt: 0, message: "must be positive"

  def initialize(@email : String, @age : Int32)
  end
end

Person.new("a@example.com", 0).errors.map(&.message)   # => ["must be positive"]
```

## Custom Validators

For anything the rules cannot say (uniqueness, optional values, cross-field checks, context-dependent rules) subclass
`CQL::ActiveRecord::Validations::CustomValidator`, return the failures from `valid?` and attach it with `use`. The
class has all the rule predicates available as helper methods (`presence?`, `gt?`, `match?`, ...):

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :orders do
    primary :id, Int64
    column :number, String
    column :total, Float64
    column :discount, Float64, null: true
  end
end

class OrderRules < CQL::ActiveRecord::Validations::CustomValidator
  def initialize(@record : Order)
  end

  def valid? : Array(CQL::ActiveRecord::Validations::Error)
    errors = [] of CQL::ActiveRecord::Validations::Error

    # optional value: only validated when present
    if discount = @record.discount
      errors << CQL::ActiveRecord::Validations::Error.new(:discount, "cannot exceed the total") if discount > @record.total
    end

    # only on create
    if @record.new_record? && Order.exists?(number: @record.number)
      errors << CQL::ActiveRecord::Validations::Error.new(:number, "has already been taken")
    end

    errors
  end
end

class Order
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :orders

  property number : String
  property total : Float64
  property discount : Float64?

  validate :total, gt: 0.0
  use OrderRules

  def initialize(@number : String, @total : Float64, @discount : Float64? = nil)
  end
end

Order.new("A-1", 10.0, 20.0).errors.map(&.message)   # => ["cannot exceed the total"]
```

## Checking Validity

### valid?

Runs the validations and returns `true` when there are no errors. It does not run callbacks.

### errors

Returns `Array(CQL::ActiveRecord::Validations::Error)`; each error has a `field` (`Symbol`) and a `message` (`String`).
There is no `full_messages`, `on(:field)` or `errors.add`; build those from the array:

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

user = User.new("", "nope")

user.valid?                                   # => false
user.errors.each { |error| puts "#{error.field}: #{error.message}" }
messages = user.errors.map(&.message)         # => ["name must be present", "email must match the pattern /@/"]
by_field = user.errors.group_by(&.field)      # Hash(Symbol, Array(Error))
name_errors = user.errors.select { |error| error.field == :name }
```

### validate!

Raises `CQL::ActiveRecord::Validations::ValidationError` (message: all error messages joined with `,`) when invalid and
returns `true` otherwise. `save`, `save!` and the instance `create!` call it, so they raise the same error for an invalid
record; `save` returns `false` only when a callback returns `false`.

The class-level `create!(**fields)`, `update!`, `update_by`, `update_all` and the bulk deletes do not validate.

## Validation Lifecycle

`save` (and `save!`) performs, in order:

1. `created_at`/`updated_at` are set
2. `before_validation` callbacks
3. `after_validation` callbacks
4. validation (`validate!`, raising `ValidationError` when invalid)
5. `before_save`, then `before_create` or `before_update`
6. the `INSERT` or `UPDATE`
7. `after_create` or `after_update`, then `after_save`

Note that `after_validation` runs before the rules are evaluated in this release, so it cannot inspect the result;
use `before_save` for work that needs a valid record. A callback returning `false` stops the sequence and `save`
returns `false`.

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

  before_validation :normalize_data

  validate :email, match: /@/

  def initialize(@name : String, @email : String)
  end

  private def normalize_data
    @email = email.downcase.strip
    @name = name.strip
    true
  end
end

User.new(" Ada ", " ADA@EXAMPLE.COM ").save
```

## Complete Example

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    column :password_hash, String, null: true
    column :age, Int32, null: true
    column :role, String, default: "user"
    column :terms_accepted, Bool, default: false
    timestamps
  end
end

class AdminEmail < CQL::ActiveRecord::Validations::CustomValidator
  def initialize(@record : User)
  end

  def valid? : Array(CQL::ActiveRecord::Validations::Error)
    errors = [] of CQL::ActiveRecord::Validations::Error
    if @record.role == "admin" && !@record.email.ends_with?("@company.com")
      errors << CQL::ActiveRecord::Validations::Error.new(:email, "admins must use company email")
    end
    if age = @record.age
      errors << CQL::ActiveRecord::Validations::Error.new(:age, "must be between 1 and 149") unless (1..149).includes?(age)
    end
    errors
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String
  property password_hash : String?
  property age : Int32?
  property role : String = "user"
  property terms_accepted : Bool = false
  property created_at : Time?
  property updated_at : Time?

  validate :name, presence: true, size: 2..100
  validate :email, presence: true, match: /@/
  validate :role, in: %w(user admin moderator)
  validate :terms_accepted, accept: true

  use AdminEmail

  def initialize(@name : String, @email : String)
  end
end

user = User.new("Ada", "ada@example.com")
user.terms_accepted = true
user.save!
```

## See Also

- [CQL API Reference](cql-api.md)
- [How to Validate Models](../../how-to/validation/validate-models.md)
