# How to Validate Requests

This guide shows you how to add validation to your request contracts.

## Basic Validation

Add the `validate` macro to your request struct:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true
  validate email, presence: true
end
```

## Validation Rules

### Presence

Ensure a field is not empty:

```crystal
validate name, presence: true
```

### Length

Validate string length:

```crystal
validate name, length: {min: 2, max: 100}
validate bio, length: {max: 500}
validate code, length: {is: 6}
```

### Format

Validate against a regular expression:

```crystal
validate email, format: /@/
validate phone, format: /^\d{10}$/
validate slug, format: /^[a-z0-9-]+$/
```

### Numericality

Validate numeric values:

```crystal
validate age, numericality: {greater_than: 0, less_than: 150}
validate quantity, numericality: {greater_than_or_equal_to: 1}
validate price, numericality: {greater_than: 0}
```

### Inclusion

Validate value is in a set:

```crystal
validate status, inclusion: {in: ["pending", "active", "archived"]}
validate role, inclusion: {in: ["admin", "user", "guest"]}
```

### Exclusion

Validate value is not in a set:

```crystal
validate username, exclusion: {in: ["admin", "root", "system"]}
```

## Combining Validations

Apply multiple rules to one field:

```crystal
struct RegistrationRequest
  include Azu::Request

  getter username : String
  getter password : String
  getter email : String

  def initialize(@username = "", @password = "", @email = "")
  end

  validate username, presence: true, length: {min: 3, max: 20}
  validate password, presence: true, length: {min: 8}
  validate email, presence: true, format: /@/
end
```

## Custom Validation

Add custom validation logic:

```crystal
struct OrderRequest
  include Azu::Request

  getter items : Array(OrderItem)
  getter coupon_code : String?

  def initialize(@items = [] of OrderItem, @coupon_code = nil)
  end

  def validate
    super  # Run standard validations first

    if items.empty?
      errors << Error.new(:items, "must have at least one item")
    end

    if coupon = coupon_code
      unless valid_coupon?(coupon)
        errors << Error.new(:coupon_code, "is invalid or expired")
      end
    end
  end

  private def valid_coupon?(code : String) : Bool
    Coupon.valid?(code)
  end
end
```

## Conditional Validation

Validate based on conditions:

```crystal
struct PaymentRequest
  include Azu::Request

  getter payment_type : String
  getter card_number : String?
  getter bank_account : String?

  def initialize(@payment_type = "", @card_number = nil, @bank_account = nil)
  end

  validate payment_type, presence: true

  def validate
    super

    case payment_type
    when "card"
      if card_number.nil? || card_number.try(&.empty?)
        errors << Error.new(:card_number, "is required for card payments")
      end
    when "bank"
      if bank_account.nil? || bank_account.try(&.empty?)
        errors << Error.new(:bank_account, "is required for bank payments")
      end
    end
  end
end
```

## Using Validated Requests in Endpoints

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Request is automatically validated before call
    # Access validated data via the request object
    user = User.create!(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    status 201
    UserResponse.new(user)
  end
end
```

## See Also

- [Handle Validation Errors](handle-validation-errors.md)
- [Validate Models](validate-models.md)
