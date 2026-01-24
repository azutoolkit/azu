# Database Validations Reference

Reference for CQL model validations.

## Validation Macro

### validate

Add validation rules to model fields.

```crystal
validate field_name, rule: value, ...
```

## Validation Rules

### presence

Field must not be empty/nil.

```crystal
validate name, presence: true
```

**Fails when:**
- Value is `nil`
- String is empty or whitespace only
- Array/Hash is empty

### length

String length constraints.

```crystal
validate name, length: {min: 2}
validate name, length: {max: 100}
validate name, length: {min: 2, max: 100}
validate code, length: {is: 6}
```

**Options:**
- `min : Int32` - Minimum length
- `max : Int32` - Maximum length
- `is : Int32` - Exact length

### format

Match regular expression.

```crystal
validate email, format: {with: /\A[^@\s]+@[^@\s]+\z/}
validate slug, format: {with: /\A[a-z0-9-]+\z/}
validate phone, format: {with: /\A\d{10}\z/}
```

**Options:**
- `with : Regex` - Pattern to match

### numericality

Numeric value constraints.

```crystal
validate age, numericality: {greater_than: 0}
validate age, numericality: {greater_than_or_equal_to: 18}
validate age, numericality: {less_than: 150}
validate age, numericality: {less_than_or_equal_to: 120}
validate quantity, numericality: {equal_to: 1}
validate count, numericality: {other_than: 0}
validate price, numericality: {odd: true}
validate pairs, numericality: {even: true}
```

**Options:**
- `greater_than : Number`
- `greater_than_or_equal_to : Number`
- `less_than : Number`
- `less_than_or_equal_to : Number`
- `equal_to : Number`
- `other_than : Number`
- `odd : Bool`
- `even : Bool`

### inclusion

Value must be in set.

```crystal
validate status, inclusion: {in: ["pending", "active", "archived"]}
validate role, inclusion: {in: Role.values.map(&.to_s)}
```

**Options:**
- `in : Array` - Allowed values

### exclusion

Value must not be in set.

```crystal
validate username, exclusion: {in: ["admin", "root", "system"]}
```

**Options:**
- `in : Array` - Forbidden values

### uniqueness

Value must be unique in database.

```crystal
validate email, uniqueness: true
validate slug, uniqueness: {scope: :category_id}
validate code, uniqueness: {case_sensitive: false}
```

**Options:**
- `scope : Symbol | Array(Symbol)` - Columns to scope uniqueness
- `case_sensitive : Bool` - Case-sensitive comparison (default: true)

### acceptance

Boolean field must be true.

```crystal
validate terms_accepted, acceptance: true
```

### confirmation

Field must match confirmation field.

```crystal
validate password, confirmation: true
# Expects password_confirmation field
```

## Validation Options

### allow_nil

Skip validation if value is nil.

```crystal
validate age, numericality: {greater_than: 0}, allow_nil: true
```

### allow_blank

Skip validation if value is blank.

```crystal
validate bio, length: {max: 500}, allow_blank: true
```

### on

Run validation only in specific context.

```crystal
validate password, presence: true, on: :create
validate password, length: {min: 8}, on: :create
```

**Values:**
- `:create` - Only on create
- `:update` - Only on update
- `:save` - On create and update (default)

### if / unless

Conditional validation.

```crystal
validate phone, presence: true, if: :requires_phone?
validate nickname, presence: true, unless: :has_name?

private def requires_phone?
  notification_method == "sms"
end
```

### message

Custom error message.

```crystal
validate email, presence: {message: "is required for registration"}
validate age, numericality: {greater_than: 0, message: "must be positive"}
```

## Custom Validation

### validate method

Override for custom logic.

```crystal
class Order
  include CQL::Model(Order, Int64)

  property items : Array(OrderItem)
  property total : Float64

  def validate
    super  # Run standard validations

    if items.empty?
      errors.add(:items, "must have at least one item")
    end

    if total != items.sum(&.price)
      errors.add(:total, "doesn't match item sum")
    end
  end
end
```

### errors.add

Add custom error.

```crystal
errors.add(:field, "message")
errors.add(:base, "general error message")
```

## Checking Validity

### valid?

Returns true if all validations pass.

```crystal
user = User.new(name: "")
user.valid?  # => false
```

### invalid?

Returns true if any validation fails.

```crystal
user.invalid?  # => true
```

### errors

Access validation errors.

```crystal
user.errors.each do |error|
  puts "#{error.field}: #{error.message}"
end

user.errors.full_messages  # => ["Name can't be blank"]
user.errors.on(:name)      # => ["can't be blank"]
```

## Validation Lifecycle

1. `before_validation` callback
2. Run validations
3. `after_validation` callback
4. If valid, proceed with save
5. If invalid, abort operation

```crystal
class User
  include CQL::Model(User, Int64)

  before_validation :normalize_data

  private def normalize_data
    @email = email.downcase.strip
    @name = name.strip
  end
end
```

## Complete Example

```crystal
class User
  include CQL::Model(User, Int64)
  db_context MyDB, :users

  property id : Int64?
  property name : String
  property email : String
  property password_hash : String?
  property age : Int32?
  property role : String
  property terms_accepted : Bool

  # Basic validations
  validate name, presence: true, length: {min: 2, max: 100}
  validate email, presence: true, format: {with: /@/}, uniqueness: true
  validate role, inclusion: {in: ["user", "admin", "moderator"]}
  validate terms_accepted, acceptance: true, on: :create

  # Conditional validation
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true

  # Password validation only on create
  validate password_hash, presence: true, on: :create

  # Custom validation
  def validate
    super

    if role == "admin" && !email.ends_with?("@company.com")
      errors.add(:email, "admins must use company email")
    end
  end
end
```

## See Also

- [CQL API Reference](cql-api.md)
- [How to Validate Models](../../how-to/validation/validate-models.md)
