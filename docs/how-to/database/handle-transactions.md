# How to Handle Transactions

This guide shows you how to use database transactions for atomic operations.

## Basic Transaction

Wrap operations in a transaction block:

```crystal
AcmeDB.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")
  Profile.create!(user_id: user.id, bio: "Hello!")
  Account.create!(user_id: user.id, balance: 0.0)
end
```

If any operation fails, all changes are rolled back.

## Transaction with Return Value

```crystal
user = AcmeDB.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")
  Profile.create!(user_id: user.id)
  user  # Return the user
end

puts user.id  # Use the created user
```

## Manual Rollback

Explicitly rollback a transaction:

```crystal
AcmeDB.transaction do |tx|
  user = User.create!(name: "Alice", email: "alice@example.com")

  if some_condition_fails
    tx.rollback
    next  # Exit the block
  end

  complete_setup(user)
end
```

## Error Handling

Handle transaction errors:

```crystal
begin
  AcmeDB.transaction do
    transfer_funds(from_account, to_account, amount)
  end
  puts "Transfer successful"
rescue ex : CQL::TransactionError
  puts "Transaction failed: #{ex.message}"
rescue ex : CQL::RecordInvalid
  puts "Validation failed: #{ex.message}"
end
```

## Nested Transactions (Savepoints)

Use savepoints for nested operations:

```crystal
AcmeDB.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")

  AcmeDB.transaction(savepoint: true) do
    # This is a savepoint, not a new transaction
    create_optional_resources(user)
  rescue
    # Only this inner block is rolled back
    Log.warn { "Optional resources failed" }
  end

  # User creation is preserved
  create_required_resources(user)
end
```

## Transaction Isolation Levels

Set isolation level for a transaction:

```crystal
AcmeDB.transaction(isolation: :serializable) do
  # Highest isolation level
  process_financial_transaction
end

# Available levels:
# :read_uncommitted
# :read_committed
# :repeatable_read
# :serializable
```

## Locking Records

### Pessimistic Locking

Lock records for update:

```crystal
AcmeDB.transaction do
  # Lock the row for update
  account = Account.lock.find(account_id)

  # No other transaction can modify this row
  account.balance -= amount
  account.save!
end
```

### Select for Update

```crystal
AcmeDB.transaction do
  accounts = Account.where(user_id: user_id)
    .lock("FOR UPDATE")
    .all

  accounts.each do |account|
    process_account(account)
  end
end
```

## Transfer Example

Complete money transfer with transactions:

```crystal
def transfer(from_id : Int64, to_id : Int64, amount : Float64)
  raise "Invalid amount" if amount <= 0

  AcmeDB.transaction do
    # Lock both accounts to prevent race conditions
    from = Account.lock.find(from_id)
    to = Account.lock.find(to_id)

    raise "Insufficient funds" if from.balance < amount

    from.balance -= amount
    to.balance += amount

    from.save!
    to.save!

    # Record the transaction
    Transaction.create!(
      from_account_id: from_id,
      to_account_id: to_id,
      amount: amount,
      completed_at: Time.utc
    )
  end
end
```

## Batch Operations

Process batches within transactions:

```crystal
def import_users(records : Array(Hash))
  # Process in batches of 100
  records.each_slice(100) do |batch|
    AcmeDB.transaction do
      batch.each do |data|
        User.create!(
          name: data["name"],
          email: data["email"]
        )
      end
    end
  end
end
```

## Transaction Callbacks

Run code after transaction commits:

```crystal
class Order
  include CQL::Model(Order, Int64)

  after_commit :send_confirmation_email, on: :create
  after_rollback :log_failure

  private def send_confirmation_email
    # Only runs if transaction commits
    Mailer.order_confirmation(self).deliver
  end

  private def log_failure
    Log.error { "Order creation rolled back: #{id}" }
  end
end
```

## Read-Only Transactions

For read-heavy operations:

```crystal
AcmeDB.transaction(read_only: true) do
  # Optimized for reads, no write locks
  generate_report
end
```

## Best Practices

1. **Keep transactions short** - Long transactions hold locks
2. **Order lock acquisition** - Always lock in same order to prevent deadlocks
3. **Handle failures** - Always rescue and handle transaction failures
4. **Don't mix concerns** - Avoid external API calls inside transactions
5. **Use appropriate isolation** - Higher isolation = lower concurrency

```crystal
# Good: Short, focused transaction
AcmeDB.transaction do
  order.status = "completed"
  order.save!
  inventory.reduce!(order.items)
end

# Then do external operations
send_notification(order)  # Outside transaction
```

## See Also

- [Query Data](query-data.md)
- [Create Models](create-models.md)
