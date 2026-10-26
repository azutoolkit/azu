---
description: Use database transactions with CQL for atomic operations.
---

# Handle transactions

Before you start: a project made by `azu new` and models for your tables (see [Create models](create-models.md)). The
examples on this page use these tables and models, laid out in the files `azu new` and `azu generate model` write:

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
    text :email
  end

  table :accounts do
    primary :id, Int64
    bigint :user_id
    column :balance, Float64
  end

  table :transfers do
    primary :id, Int64
    bigint :from_account_id
    bigint :to_account_id
    column :amount, Float64
    timestamp :completed_at
  end

  table :orders do
    primary :id, Int64
    column :total, Float64
  end
end

# src/models/user.cr
class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :users

  property name : String
  property email : String

  validate :name, presence: true

  def initialize(@name : String, @email : String)
  end
end

# src/models/account.cr
class Account
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :accounts

  property user_id : Int64
  property balance : Float64

  def initialize(@user_id : Int64, @balance : Float64 = 0.0)
  end
end

# src/models/transfer.cr
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

# src/models/order.cr
class Order
  include CQL::ActiveRecord::Model(Int64)
  db_context AcmeDB, :orders

  property total : Float64

  def initialize(@total : Float64)
  end
end
```

## Basic transaction

`schema.transaction` (or `Model.transaction`, which uses the model's schema) opens a transaction, commits when the block
returns and rolls back when it raises. Queries inside the block run on the transaction's connection automatically:

```crystal
AcmeDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")
  User.create!(name: "Bob", email: "bob@example.com")
end

User.transaction do |tx|
  User.create!(name: "Carol", email: "carol@example.com")
end
```

If any statement raises, every change in the block is rolled back and the exception propagates. In development each
transaction appears in the dev dashboard's Database tab with its duration and outcome.

## Transaction with return value

The block's value is the value of the call:

```crystal
user = AcmeDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")
end

user.try { |created| puts created.id }
```

The result is `nil` when the block rolled back through `DB::Rollback` (below), so the type is a union with `Nil`.

## Manual rollback

Raise `DB::Rollback` to roll back and leave the block quietly: the transaction is rolled back, nothing propagates and
the call returns `nil`. Calling `tx.rollback` also rolls back, but execution continues until the block ends:

```crystal
def import(name : String, email : String, dry_run : Bool) : Nil
  AcmeDB.transaction do
    User.create!(name: name, email: email)
    raise DB::Rollback.new if dry_run
  end
end

import("Alice", "alice@example.com", dry_run: true)
User.count                           # => 0
```

## Error handling

Exceptions leave the transaction rolled back and reach your `rescue`, so rescue around the `transaction` call, not
inside it. Records saved with `save`/`save!` raise `CQL::ActiveRecord::Validations::ValidationError` when invalid;
`create!(**fields)` and `update!` skip validations and callbacks, so build records with `new` and call `save!` when
you need them (see [Database validations](../../reference/database/validations.md#checking-validity)):

```crystal
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

User.count                           # => 0
```

## Nested transactions (savepoints)

A `transaction` called inside another one opens a SAVEPOINT on the outer transaction's connection. A failure inside
only undoes the inner block:

```crystal
AcmeDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")

  begin
    User.transaction do
      User.create!(name: "Optional", email: "optional@example.com")
      raise "optional step failed"
    end
  rescue ex
    Log.warn { "Optional step rolled back: #{ex.message}" }
  end

  User.create!(name: "Required", email: "required@example.com")
end

User.pluck(:name)                    # => ["Alice", "Required"]
```

## One transaction per request

`Azu::CQL::Middleware` runs everything after it in the handler chain in one transaction: it commits when the response
status is below 400 and rolls back on an exception or an error status. Add it to the handlers of your app, after
`Rescuer`:

```crystal
# src/acme.cr
module Acme
  include Azu

  def self.handlers : Array(HTTP::Handler)
    [
      Azu::Handler::RequestId.new,
      Azu::Handler::Logger.new,
      Azu::Handler::Rescuer.new,
      Azu::CQL::Middleware.new(AcmeDB, transaction: true),
    ] of HTTP::Handler
  end
end
```

A `transaction` an endpoint opens inside such a request is a savepoint of the request's transaction. The
[CQL bridge](../../reference/api/cql-bridge.md#azucqlmiddleware) reference lists the options and where the
middleware does not fit (streaming and WebSocket routes); the
[Working with databases](../../tutorials/working-with-databases.md) tutorial uses it.

## Isolation levels and read-only transactions

`transaction` takes no options. To change the isolation level or make a transaction read-only, issue the statement as
the first thing inside the block on the transaction's connection:

```crystal
AcmeDB.transaction do |tx|
  tx.connection.exec("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
  tx.connection.exec("SET TRANSACTION READ ONLY")
  puts tx.connection.scalar("SELECT COUNT(*) FROM accounts")
end
```

The statements are PostgreSQL syntax. `Azu::CQL.schema` picks the adapter from the URL, so the same schema runs on
PostgreSQL when `DATABASE_URL` is a `postgres://` URL.

## Locking records

PostgreSQL, CockroachDB and MySQL support row locks; SQLite raises `CQL::DialectError` when SQL with a lock is
generated, because it serializes writers instead. `QueryBuilder` has no `lock` method, so reach the underlying query
with `with_query`. `lock` takes `:update` (default) or `:share`, and `skip_locked:` or `nowait:`:

```crystal
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

## Transfer example

A money transfer on PostgreSQL. Lock both rows in a fixed order (lowest id first) so two opposite transfers cannot
deadlock:

```crystal
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

## Batch operations

Commit in chunks so a large import does not hold one huge transaction:

```crystal
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

## After-commit work

CQL has no `after_commit` or `after_rollback` callbacks. Do the follow-up work after `transaction` returns, so it only
runs when the transaction committed:

```crystal
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

Inside a request wrapped by `Azu::CQL::Middleware` the block above is a savepoint, so the order is committed only
when the request's transaction commits.

## See also

- [Query data](query-data.md)
- [Create models](create-models.md)
- [CQL bridge](../../reference/api/cql-bridge.md)
- [Database dashboard](../../reference/database-dashboard.md)
