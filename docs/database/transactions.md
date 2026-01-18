# Transactions

Transactions ensure multiple database operations succeed or fail together, maintaining data consistency.

## Basic Transactions

```crystal
AppDB.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")
  profile = UserProfile.create!(user_id: user.id, bio: "Hello!")
  # Both records saved, or neither is saved
end
```

## Automatic Rollback

If an exception is raised inside a transaction, all changes are rolled back:

```crystal
AppDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")
  raise "Something went wrong!"
  # User is NOT saved - transaction rolled back
end
```

## Manual Rollback

Explicitly rollback a transaction:

```crystal
AppDB.transaction do |tx|
  user = User.create!(name: "Alice", email: "alice@example.com")

  if some_condition_fails
    tx.rollback
    # User is NOT saved
  end
end
```

## Nested Transactions (Savepoints)

Nest transactions using savepoints for partial rollback:

```crystal
AppDB.transaction do
  user = User.create!(name: "Alice", email: "alice@example.com")

  AppDB.transaction do |inner|
    post = Post.create!(user_id: user.id, title: "First Post")

    if post.title.empty?
      inner.rollback
      # Only the post is rolled back, user remains
    end
  end

  # User is saved even if inner transaction rolled back
end
```

## Transaction Return Values

Transactions return the value of the last expression:

```crystal
user = AppDB.transaction do
  User.create!(name: "Alice", email: "alice@example.com")
end

puts user.id  # User was created and returned
```

## Using with Azu Endpoints

```crystal
struct TransferEndpoint
  include Azu::Endpoint(TransferRequest, TransferResponse)

  post "/transfers"

  def call : TransferResponse
    raise Azu::Response::ValidationError.new(request.errors) unless request.valid?

    transfer = AppDB.transaction do
      # Debit source account
      source = Account.find(request.from_account_id)
      raise Azu::Response::BadRequest.new("Insufficient funds") if source.balance < request.amount
      source.balance -= request.amount
      source.save!

      # Credit destination account
      dest = Account.find(request.to_account_id)
      dest.balance += request.amount
      dest.save!

      # Record transfer
      Transfer.create!(
        from_account_id: source.id,
        to_account_id: dest.id,
        amount: request.amount
      )
    end

    TransferResponse.new(transfer)

  rescue ex
    # Transaction automatically rolled back on any exception
    raise Azu::Response::BadRequest.new(ex.message)
  end
end
```

## Multi-Model Operations

```crystal
struct CreateOrderEndpoint
  include Azu::Endpoint(OrderRequest, OrderResponse)

  post "/orders"

  def call : OrderResponse
    order = AppDB.transaction do
      # Create order
      order = Order.create!(
        user_id: current_user.id,
        status: "pending"
      )

      # Create order items
      request.items.each do |item|
        product = Product.find(item.product_id)

        # Check stock
        if product.stock < item.quantity
          raise Azu::Response::BadRequest.new("Insufficient stock for #{product.name}")
        end

        # Create order item
        OrderItem.create!(
          order_id: order.id,
          product_id: product.id,
          quantity: item.quantity,
          price: product.price
        )

        # Decrement stock
        product.stock -= item.quantity
        product.save!
      end

      # Calculate total
      order.total = order.items.sum(&.price * &.quantity)
      order.save!

      order
    end

    OrderResponse.new(order)
  end
end
```

## Transaction Isolation

Configure isolation level for specific requirements:

```crystal
# Read committed (default)
AppDB.transaction do
  # Normal transaction
end

# Serializable (strictest isolation)
AppDB.transaction(isolation: :serializable) do
  # Prevents phantom reads
end
```

## Error Handling Patterns

### Retry on Conflict

```crystal
def create_with_retry(attrs, max_retries = 3)
  retries = 0
  begin
    AppDB.transaction do
      User.create!(attrs)
    end
  rescue CQL::UniqueViolation
    retries += 1
    if retries < max_retries
      attrs[:email] = "#{attrs[:email]}_#{retries}"
      retry
    else
      raise
    end
  end
end
```

### Conditional Commit

```crystal
result = AppDB.transaction do |tx|
  user = User.create!(name: "Alice", email: "alice@example.com")

  # External service call
  unless EmailService.send_welcome(user)
    tx.rollback
    nil
  else
    user
  end
end

if result
  puts "User created and email sent"
else
  puts "Transaction rolled back"
end
```

## Best Practices

1. **Keep transactions short**: Long transactions hold locks and reduce concurrency
2. **Avoid external calls**: Don't make HTTP requests inside transactions
3. **Handle exceptions**: Always rescue and handle transaction failures gracefully
4. **Use savepoints sparingly**: They add overhead; prefer flat transactions when possible
5. **Test rollback behavior**: Ensure your application handles rollbacks correctly

## Next Steps

- [Models](models.md) - CRUD operations within transactions
- [Queries](queries.md) - Query data within transaction scope
