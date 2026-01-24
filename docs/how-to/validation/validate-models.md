# How to Validate Models

This guide shows you how to add validation to your CQL database models.

## Basic Model Validation

Add validations to your CQL model:

```crystal
class User
  include CQL::Model(User, Int64)

  property id : Int64?
  property name : String
  property email : String
  property age : Int32?

  validate name, presence: true, length: {min: 2, max: 100}
  validate email, presence: true, format: /@/
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true
end
```

## Validation Rules

### Presence

```crystal
validate name, presence: true
```

### Uniqueness

Ensure a value is unique in the database:

```crystal
validate email, uniqueness: true
validate username, uniqueness: {scope: :organization_id}
```

### Length

```crystal
validate title, length: {min: 5, max: 200}
validate description, length: {max: 1000}
```

### Format

```crystal
validate email, format: {with: /\A[^@\s]+@[^@\s]+\z/}
validate slug, format: {with: /\A[a-z0-9-]+\z/}
```

### Numericality

```crystal
validate quantity, numericality: {greater_than_or_equal_to: 0}
validate price, numericality: {greater_than: 0}
```

### Inclusion

```crystal
validate status, inclusion: {in: ["draft", "published", "archived"]}
```

## Custom Model Validation

```crystal
class Order
  include CQL::Model(Order, Int64)

  property id : Int64?
  property user_id : Int64
  property total : Float64
  property items : Array(OrderItem)

  def validate
    super

    if items.empty?
      errors.add(:items, "must have at least one item")
    end

    if total <= 0
      errors.add(:total, "must be positive")
    end

    validate_inventory
  end

  private def validate_inventory
    items.each do |item|
      product = Product.find(item.product_id)
      if product && product.stock < item.quantity
        errors.add(:items, "insufficient stock for #{product.name}")
      end
    end
  end
end
```

## Validation Callbacks

Run code before or after validation:

```crystal
class User
  include CQL::Model(User, Int64)

  property name : String
  property email : String
  property normalized_email : String?

  before_validation :normalize_email

  private def normalize_email
    @normalized_email = email.downcase.strip
  end
end
```

## Checking Validity

```crystal
user = User.new(name: "", email: "invalid")

if user.valid?
  user.save!
else
  puts user.errors.full_messages
end

# Or use save with return value
if user.save
  puts "Saved!"
else
  puts user.errors.full_messages
end
```

## Skipping Validations

When necessary, skip validations:

```crystal
# Skip all validations
user.save!(validate: false)

# Update specific attribute without validation
user.update_column(:last_login, Time.utc)
```

## Validation Contexts

Use contexts for different validation scenarios:

```crystal
class User
  include CQL::Model(User, Int64)

  property password : String?

  validate password, presence: true, on: :create
  validate password, length: {min: 8}, on: :create
end

# Validations run on create
user = User.new(name: "Alice", email: "alice@example.com")
user.save  # password validation runs

# Validations don't run on update for password
user.name = "Alice Smith"
user.save  # password validation skipped
```

## See Also

- [Validate Requests](validate-requests.md)
- [Handle Validation Errors](handle-validation-errors.md)
