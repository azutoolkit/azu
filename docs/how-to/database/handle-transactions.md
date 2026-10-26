# Handle transactions

This guide shows you how to use database transactions with CQL for atomic operations.

Every example defines the schema and models it uses; in an application they live in their own files.

## Basic Transaction

`schema.transaction` (or `Model.transaction`, which uses the model's schema) opens a transaction, commits when the block
returns and rolls back when it raises. Queries inside the block run on the transaction's connection automatically:

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

  def initialize(@name : String, @email : String)
  end
end

AcmeDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")
  User.create!(name: "Bob", email: "bob@example.com")
end

User.transaction do |tx|
  User.create!(name: "Carol", email: "carol@example.com")
end
```

If any statement raises, every change in the block is rolled back and the exception propagates.

## Transaction with Return Value

The block's value is the value of the call:

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

  def initialize(@name : String, @email : String)
  end
end

user = AcmeDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")
end

user.try { |created| puts created.id }
```

The result is `nil` when the block rolled back through `DB::Rollback` (below), so the type is a union with `Nil`.

## Manual Rollback

Raise `DB::Rollback` to roll back and leave the block quietly: the transaction is rolled back, nothing propagates and
the call returns `nil`. Calling `tx.rollback` also rolls back, but execution continues until the block ends:

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

  def initialize(@name : String, @email : String)
  end
end

def import(name : String, email : String, dry_run : Bool) : Nil
  AcmeDB.transaction do
    User.create!(name: name, email: email)
    raise DB::Rollback.new if dry_run
  end
end

import("Alice", "alice@example.com", dry_run: true)
```

## Error Handling

Exceptions leave the transaction rolled back and reach your `rescue`. Records saved with `save`/`save!` raise
`CQL::ActiveRecord::Validations::ValidationError` when invalid; `create!(**fields)` does not validate at all (see
[Validate Models](../validation/validate-models.md)):

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

begin
  AcmeDB.transaction do
    User.new("Alice", "alice@example.com").save!
    User.new("", "invalid").save!
  end
  puts "Saved both users"
rescue ex : CQL::ActiveRecord::Validations::ValidationError
  puts "Validation failed, nothing was saved: #{ex.message}"
rescue ex : DB::Error
  puts "Database error: #{ex.message}"
end
```

## Nested Transactions (Savepoints)

Pass the outer transaction to `Model.transaction` to open a savepoint. A failure inside only undoes the inner block:

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

  def initialize(@name : String, @email : String)
  end
end

AcmeDB.transaction do |outer|
  User.create!(name: "Alice", email: "alice@example.com")

  begin
    User.transaction(outer) do |_inner|
      User.create!(name: "Optional", email: "optional@example.com")
      raise "optional step failed"
    end
  rescue ex
    Log.warn { "Optional step rolled back: #{ex.message}" }
  end

  # Alice is still part of the outer transaction
  User.create!(name: "Required", email: "required@example.com")
end
```

## Isolation Levels and Read-Only Transactions

CQL's `transaction` takes no options. To change the isolation level or make a transaction read-only, issue the
statement as the first thing inside the block on the transaction's connection:

```crystal
require "cql"
require "pg"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :accounts do
    primary :id, Int64
    column :balance, Float64
  end
end

AcmeDB.transaction do |tx|
  tx.connection.exec("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
  tx.connection.exec("SET TRANSACTION READ ONLY")
  puts tx.connection.scalar("SELECT COUNT(*) FROM accounts")
end
```

The statements are PostgreSQL syntax.

## Locking Records

PostgreSQL, CockroachDB and MySQL support row locks; SQLite raises `CQL::DialectError` when SQL with a lock is
generated, because it serializes writers instead. `QueryBuilder` has no `lock` method, so reach the underlying query
with `with_query`. `lock` takes `:update` (default) or `:share`, and `skip_locked:` or `nowait:`:

```crystal
require "cql"
require "pg"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :accounts do
    primary :id, Int64
    column :user_id, Int64
    column :balance, Float64
  end
end

class Account
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :accounts

  property user_id : Int64
  property balance : Float64

  def initialize(@user_id : Int64, @balance : Float64 = 0.0)
  end
end

AcmeDB.transaction do
  # SELECT ... FROM accounts WHERE accounts.id = $1 FOR UPDATE
  account = Account.where(id: 1_i64).with_query(&.lock).first!
  account.balance -= 10.0
  account.save!
end

AcmeDB.transaction do
  # Skip rows another transaction has locked (job-queue style)
  Account.where(user_id: 7_i64).with_query(&.lock(skip_locked: true)).all
end
```

## Transfer Example

A complete money transfer. Lock both rows in a fixed order (lowest id first) so two opposite transfers cannot deadlock:

```crystal
require "cql"
require "pg"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :accounts do
    primary :id, Int64
    column :balance, Float64
  end

  table :transfers do
    primary :id, Int64
    column :from_account_id, Int64
    column :to_account_id, Int64
    column :amount, Float64
    column :completed_at, Time
  end
end

class Account
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :accounts

  property balance : Float64

  def initialize(@balance : Float64 = 0.0)
  end
end

class Transfer
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :transfers

  property from_account_id : Int64
  property to_account_id : Int64
  property amount : Float64
  property completed_at : Time

  def initialize(@from_account_id : Int64, @to_account_id : Int64, @amount : Float64, @completed_at : Time = Time.utc)
  end
end

def locked_account(id : Int64) : Account
  Account.where(id: id).with_query(&.lock).first!
end

def transfer(from_id : Int64, to_id : Int64, amount : Float64) : Nil
  raise ArgumentError.new("Invalid amount") if amount <= 0

  AcmeDB.transaction do
    first_id, second_id = {from_id, to_id}.minmax
    accounts = {first_id => locked_account(first_id), second_id => locked_account(second_id)}
    from = accounts[from_id]
    to = accounts[to_id]

    raise "Insufficient funds" if from.balance < amount

    from.balance -= amount
    to.balance += amount
    from.save!
    to.save!

    Transfer.create!(from_account_id: from_id, to_account_id: to_id, amount: amount, completed_at: Time.utc)
  end
end

transfer(1_i64, 2_i64, 25.0)
```

## Batch Operations

Commit in chunks so a large import does not hold one huge transaction:

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

  def initialize(@name : String, @email : String)
  end
end

def import_users(records : Array(Hash(String, String))) : Nil
  records.each_slice(100) do |batch|
    AcmeDB.transaction do
      batch.each do |data|
        User.create!(name: data["name"], email: data["email"])
      end
    end
  end
end

import_users([{"name" => "Alice", "email" => "alice@example.com"}])
```

## After-Commit Work

CQL has no `after_commit` or `after_rollback` callbacks. Do the follow-up work after `transaction` returns, so it only
runs when the transaction committed:

```crystal
require "cql"
require "sqlite3"

AcmeDB = CQL::Schema.define(:acme, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/acme.db") do
  table :orders do
    primary :id, Int64
    column :total, Float64
  end
end

class Order
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :orders

  property total : Float64

  def initialize(@total : Float64)
  end
end

def place_order(total : Float64) : Order?
  order = AcmeDB.transaction do
    Order.create!(total: total)
  end

  # Reached only when the transaction committed
  order.try { |placed| Log.info { "order #{placed.id} placed, send the confirmation email" } }
  order
end

place_order(42.0)
```

## Transactions and the Dashboard

With `require "azu/cql"`, every transaction appears in the dev dashboard's Database tab with its duration and outcome,
and `Azu::CQL.transaction(schema) { ... }` is a thin wrapper over `schema.transaction`. See
[Database dashboard](../../reference/database-dashboard.md).

## Best Practices

1. **Keep transactions short.** Long transactions hold locks.
2. **Lock in a fixed order.** It prevents deadlocks.
3. **Handle failures.** Rescue around the `transaction` call, not inside it, so the rollback happens.
4. **Do not mix concerns.** No HTTP calls or emails inside a transaction (see [After-Commit Work](#after-commit-work)).
5. **Remember the escape hatches.** `User.create!(...)` and `update!` skip validations and callbacks; build records
   with `new` and call `save!` when you need them.

## See Also

- [Query Data](query-data.md)
- [Create Models](create-models.md)
