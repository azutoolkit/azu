---
description: Create custom error types for your Azu application.
---

# Create custom errors

An error is an `Azu::Response::Error`: an exception that is also a response. `Azu::Handler::Rescuer` catches it and
writes it with its status, in the format the `Accept` header asks for. A subclass sets the title, the status
(an `HTTP::Status`) and the list of messages through `super`, and the longer explanation in `@detail`.

## Basic custom error

Create an error by extending `Azu::Response::Error`:

```crystal
class ResourceNotFound < Azu::Response::Error
  def initialize(resource : String, id : String | Int64)
    super(title: "Not Found", status: HTTP::Status::NOT_FOUND, errors: [] of String)
    @detail = "#{resource} with id #{id} not found"
  end
end

struct ShowEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:id"

  def call : Azu::Response::Empty
    raise ResourceNotFound.new("User", params["id"])
  end
end
```

## Error with context

Keep additional data on the error and expose it in the body by overriding `json`:

```crystal
record FieldError, field : String, message : String

class ImportFailed < Azu::Response::Error
  getter rows : Array(FieldError)

  def initialize(@rows : Array(FieldError))
    super(
      title: "Import Failed",
      status: HTTP::Status::UNPROCESSABLE_ENTITY,
      errors: @rows.map { |row| "#{row.field}: #{row.message}" }
    )
    @detail = "#{@rows.size} rows could not be imported"
  end

  def json : String
    {
      error:   detail,
      details: rows.map { |row| {field: row.field, message: row.message} },
    }.to_json
  end
end
```

`errors` is the list of messages shown in the HTML, XML and plain text formats. Request validation failures have
their own class, `Azu::Response::ValidationError`; raise that one for invalid input.

## Domain-specific errors

Create errors for your domain:

```crystal
# Payment errors
class PaymentError < Azu::Response::Error
  def initialize(message : String)
    super(title: "Payment Required", status: HTTP::Status::PAYMENT_REQUIRED, errors: [] of String)
    @detail = message
  end
end

class InsufficientFundsError < PaymentError
  def initialize(required : Float64, available : Float64)
    super("Insufficient funds: need $#{required}, have $#{available}")
  end
end

class PaymentDeclinedError < PaymentError
  getter decline_code : String

  def initialize(@decline_code : String)
    super("Payment declined: #{decline_code}")
  end
end

# Inventory errors
class InventoryError < Azu::Response::Error
  def initialize(message : String)
    super(title: "Inventory Error", status: HTTP::Status::UNPROCESSABLE_ENTITY, errors: [] of String)
    @detail = message
  end
end

class OutOfStockError < InventoryError
  def initialize(product_name : String)
    super("#{product_name} is out of stock")
  end
end
```

## Error hierarchy

Create a structured error hierarchy with a machine readable code:

```crystal
module Errors
  # Base application error
  abstract class AppError < Azu::Response::Error
    getter code : String

    def initialize(title : String, status : HTTP::Status, message : String, @code : String)
      super(title: title, status: status, errors: [] of String)
      @detail = message
    end

    def json : String
      {
        error: {
          code:    code,
          message: detail,
        },
      }.to_json
    end
  end

  # Client errors (4xx)
  class BadRequest < AppError
    def initialize(message : String, code = "BAD_REQUEST")
      super("Bad Request", HTTP::Status::BAD_REQUEST, message, code)
    end
  end

  class Unauthorized < AppError
    def initialize(message = "Authentication required")
      super("Unauthorized", HTTP::Status::UNAUTHORIZED, message, "UNAUTHORIZED")
    end
  end

  class Forbidden < AppError
    def initialize(message = "Access denied")
      super("Forbidden", HTTP::Status::FORBIDDEN, message, "FORBIDDEN")
    end
  end

  class NotFound < AppError
    def initialize(resource : String)
      super("Not Found", HTTP::Status::NOT_FOUND, "#{resource} not found", "NOT_FOUND")
    end
  end

  class Conflict < AppError
    def initialize(message : String)
      super("Conflict", HTTP::Status::CONFLICT, message, "CONFLICT")
    end
  end

  class ValidationFailed < AppError
    getter details : Array(Hash(String, String))

    def initialize(@details : Array(Hash(String, String)))
      super("Validation Failed", HTTP::Status::UNPROCESSABLE_ENTITY, "Validation failed", "VALIDATION_FAILED")
    end

    def json : String
      {
        error: {
          code:    code,
          message: detail,
          details: details,
        },
      }.to_json
    end
  end

  # Server errors (5xx)
  class InternalError < AppError
    def initialize(message = "Internal server error")
      super("Internal Server Error", HTTP::Status::INTERNAL_SERVER_ERROR, message, "INTERNAL_ERROR")
    end
  end

  class ServiceUnavailable < AppError
    def initialize(service : String)
      super("Service Unavailable", HTTP::Status::SERVICE_UNAVAILABLE, "#{service} is temporarily unavailable", "SERVICE_UNAVAILABLE")
    end
  end
end
```

## Error responses

Add request details to the body. `Rescuer` calls `to_s(context)` on the error, which sets the status and picks the
format; override `json` for the JSON one and `json_content_type` if the body has its own media type:

```crystal
class ApiError < Azu::Response::Error
  getter code : String
  getter request_id : String?

  def initialize(
    message : String,
    status : HTTP::Status,
    @code : String,
    @request_id : String? = nil,
  )
    super(title: message, status: status, errors: [] of String)
  end

  def json : String
    error = {
      code:      code,
      message:   detail,
      timestamp: Time.utc.to_rfc3339,
    }

    if id = request_id
      error = error.merge({request_id: id})
    end

    {error: error}.to_json
  end
end
```

## Error handler integration

Custom errors need no handler of their own: `Rescuer` rescues every `Azu::Response::Error`, including yours.

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

## Using custom errors in endpoints

```crystal
class InsufficientFundsError < Azu::Response::Error
  def initialize(required : Float64, available : Float64)
    super(title: "Payment Required", status: HTTP::Status::PAYMENT_REQUIRED, errors: [] of String)
    @detail = "Insufficient funds: need $#{required}, have $#{available}"
  end
end

class AccountNotFound < Azu::Response::Error
  def initialize(account : String)
    super(title: "Not Found", status: HTTP::Status::NOT_FOUND, errors: [] of String)
    @detail = "#{account} not found"
  end
end

struct TransferRequest
  include Azu::Request

  getter from_account_id : Int64
  getter to_account_id : Int64
  getter amount : Float64

  def initialize(@from_account_id = 0_i64, @to_account_id = 0_i64, @amount = 0.0)
  end
end

struct TransferResponse
  include Azu::Response

  def initialize(@amount : Float64)
  end

  def render
    {transferred: @amount}.to_json
  end
end

struct TransferFundsEndpoint
  include Azu::Endpoint(TransferRequest, TransferResponse)

  post "/transfers"

  def call : TransferResponse
    balances = {1_i64 => 100.0, 2_i64 => 50.0}

    from_balance = balances[transfer_request.from_account_id]? || raise AccountNotFound.new("Source account")
    balances[transfer_request.to_account_id]? || raise AccountNotFound.new("Destination account")

    amount = transfer_request.amount
    raise Azu::Response::BadRequest.new("Amount must be positive") if amount <= 0

    if from_balance < amount
      raise InsufficientFundsError.new(amount, from_balance)
    end

    TransferResponse.new(amount)
  end
end
```

## See also

- [Handle Errors Gracefully](handle-errors-gracefully.md)
