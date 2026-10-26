# Validate requests

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

Validation is enforced before your endpoint runs: a request that breaks its contract is answered with `422` and the
failing fields, and `call` never sees it.

## Validation Rules

Every rule takes the field name, the rule and the expected value, and an optional `message:` that replaces the default
message (`Invalid field: <name>`).

### Presence

Ensure a field is not empty:

```crystal
struct NameRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end
```

### Size

Validate string length with a `Range`, or an exact size with an `Int`:

```crystal
struct ProfileRequest
  include Azu::Request

  getter name : String
  getter bio : String
  getter code : String

  def initialize(@name = "", @bio = "", @code = "")
  end

  validate name, size: 2..100
  validate bio, size: 0..500
  validate code, size: 6
end
```

### Match

Validate against a regular expression:

```crystal
struct ContactRequest
  include Azu::Request

  getter email : String
  getter phone : String
  getter slug : String

  def initialize(@email = "", @phone = "", @slug = "")
  end

  validate email, match: /@/, message: "must be an email address"
  validate phone, match: /^\d{10}$/
  validate slug, match: /^[a-z0-9-]+$/
end
```

### Comparisons

Validate numbers with `gt`, `gte`, `lt`, `lte` and `eq`. Put all the rules of one field in one `validate` call: a second
`validate` for the same field replaces the first, so `validate age, gt: 0` followed by `validate age, lt: 150` checks
only `lt: 150`.

```crystal
struct OrderLineRequest
  include Azu::Request

  getter age : Int32
  getter quantity : Int32
  getter price : Float64

  def initialize(@age = 0, @quantity = 1, @price = 0.0)
  end

  validate age, gt: 0, lt: 150
  validate quantity, gte: 1
  validate price, gt: 0.0
end
```

### In

Validate value is in a set (an `Array` or a `Range`):

```crystal
struct SettingsRequest
  include Azu::Request

  getter status : String
  getter role : String
  getter page : Int32

  def initialize(@status = "pending", @role = "user", @page = 1)
  end

  validate status, in: %w(pending active archived)
  validate role, in: %w(admin user guest)
  validate page, in: 1..100
end
```

### Exclude

Validate value is not in a set:

```crystal
struct UsernameRequest
  include Azu::Request

  getter username : String

  def initialize(@username = "")
  end

  validate username, exclude: %w(admin root system), message: "is reserved"
end
```

## Combining Validations

Apply multiple rules to one field. All of them are checked, and each failing rule adds an error:

```crystal
struct RegistrationRequest
  include Azu::Request

  getter username : String
  getter password : String
  getter email : String

  def initialize(@username = "", @password = "", @email = "")
  end

  validate username, presence: true, size: 3..20
  validate password, presence: true, size: 8..128
  validate email, presence: true, match: /@/
end
```

## Custom Validation

For rules that need code, subclass `Schema::Validator`, return the errors from `valid?`, and register it with `use`.
The validator receives the request as `@record`:

```crystal
struct OrderItem
  getter sku : String

  def initialize(@sku)
  end
end

struct OrderRequest
  include Azu::Request

  getter items : Array(OrderItem)
  getter coupon_code : String?

  def initialize(@items = [] of OrderItem, @coupon_code = nil)
  end

  use OrderValidator
end

class OrderValidator < Schema::Validator
  VALID_COUPONS = ["WELCOME10"]

  def initialize(@record : OrderRequest)
  end

  def valid? : Array(Schema::Error)
    errors = [] of Schema::Error
    errors << Schema::Error.new(:items, "must have at least one item") if @record.items.empty?

    if coupon = @record.coupon_code
      errors << Schema::Error.new(:coupon_code, "is invalid or expired") unless VALID_COUPONS.includes?(coupon)
    end
    errors
  end
end
```

## Conditional Validation

Validate based on conditions inside a validator:

```crystal
struct PaymentRequest
  include Azu::Request

  getter payment_type : String
  getter card_number : String?
  getter bank_account : String?

  def initialize(@payment_type = "", @card_number = nil, @bank_account = nil)
  end

  validate payment_type, presence: true
  use PaymentValidator
end

class PaymentValidator < Schema::Validator
  def initialize(@record : PaymentRequest)
  end

  def valid? : Array(Schema::Error)
    errors = [] of Schema::Error

    case @record.payment_type
    when "card"
      errors << Schema::Error.new(:card_number, "is required for card payments") if @record.card_number.presence.nil?
    when "bank"
      errors << Schema::Error.new(:bank_account, "is required for bank payments") if @record.bank_account.presence.nil?
    end
    errors
  end
end
```

## Using Validated Requests in Endpoints

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true
  validate email, presence: true
end

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # The request is validated before call. A request that fails never gets here.
    status 201
    UserResponse.new(create_user_request.name)
  end
end
```

## See Also

- [Handle Validation Errors](handle-validation-errors.md)
- [Validate Models](validate-models.md)
