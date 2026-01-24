# How to Create Custom Errors

This guide shows you how to create custom error types for your Azu application.

## Basic Custom Error

Create an error by extending `Azu::Response::Error`:

```crystal
class NotFoundError < Azu::Response::Error
  def initialize(resource : String, id : String | Int64)
    super("#{resource} with id #{id} not found", 404)
  end
end

# Usage
raise NotFoundError.new("User", params["id"])
```

## Error with Context

Include additional context:

```crystal
class ValidationError < Azu::Response::Error
  getter errors : Array(FieldError)

  def initialize(@errors : Array(FieldError))
    super("Validation failed", 422)
  end

  def to_json(io : IO)
    {
      error: message,
      details: errors.map { |e| {field: e.field, message: e.message} }
    }.to_json(io)
  end
end

record FieldError, field : String, message : String
```

## Domain-Specific Errors

Create errors for your domain:

```crystal
# Payment errors
class PaymentError < Azu::Response::Error
  def initialize(message : String)
    super(message, 402)  # Payment Required
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
    super(message, 422)
  end
end

class OutOfStockError < InventoryError
  def initialize(product_name : String)
    super("#{product_name} is out of stock")
  end
end
```

## Error Hierarchy

Create a structured error hierarchy:

```crystal
module Errors
  # Base application error
  abstract class AppError < Azu::Response::Error
    getter code : String

    def initialize(message : String, status : Int32, @code : String)
      super(message, status)
    end

    def to_json(io : IO)
      {
        error: {
          code: code,
          message: message
        }
      }.to_json(io)
    end
  end

  # Client errors (4xx)
  class BadRequest < AppError
    def initialize(message : String, code = "BAD_REQUEST")
      super(message, 400, code)
    end
  end

  class Unauthorized < AppError
    def initialize(message = "Authentication required")
      super(message, 401, "UNAUTHORIZED")
    end
  end

  class Forbidden < AppError
    def initialize(message = "Access denied")
      super(message, 403, "FORBIDDEN")
    end
  end

  class NotFound < AppError
    def initialize(resource : String)
      super("#{resource} not found", 404, "NOT_FOUND")
    end
  end

  class Conflict < AppError
    def initialize(message : String)
      super(message, 409, "CONFLICT")
    end
  end

  class ValidationFailed < AppError
    getter details : Array(Hash(String, String))

    def initialize(@details : Array(Hash(String, String)))
      super("Validation failed", 422, "VALIDATION_FAILED")
    end

    def to_json(io : IO)
      {
        error: {
          code: code,
          message: message,
          details: details
        }
      }.to_json(io)
    end
  end

  # Server errors (5xx)
  class InternalError < AppError
    def initialize(message = "Internal server error")
      super(message, 500, "INTERNAL_ERROR")
    end
  end

  class ServiceUnavailable < AppError
    def initialize(service : String)
      super("#{service} is temporarily unavailable", 503, "SERVICE_UNAVAILABLE")
    end
  end
end
```

## Error Responses

Create custom response formats:

```crystal
class ApiError < Azu::Response::Error
  getter code : String
  getter details : Hash(String, JSON::Any)?
  getter request_id : String?

  def initialize(
    message : String,
    status : Int32,
    @code : String,
    @details : Hash(String, JSON::Any)? = nil,
    @request_id : String? = nil
  )
    super(message, status)
  end

  def to_json(io : IO)
    response = {
      error: {
        code: code,
        message: message,
        timestamp: Time.utc.to_rfc3339
      }
    }

    response[:error][:details] = details if details
    response[:error][:request_id] = request_id if request_id

    response.to_json(io)
  end
end
```

## Error Handler Integration

Handle custom errors:

```crystal
class CustomErrorHandler < Azu::Handler::Base
  def call(context)
    call_next(context)
  rescue ex : Errors::AppError
    context.response.status_code = ex.status
    context.response.content_type = "application/json"
    ex.to_json(context.response)
  rescue ex : Azu::Response::Error
    context.response.status_code = ex.status
    context.response.content_type = "application/json"
    {error: ex.message}.to_json(context.response)
  end
end
```

## Using Custom Errors in Endpoints

```crystal
struct TransferFundsEndpoint
  include Azu::Endpoint(TransferRequest, TransferResponse)

  post "/transfers"

  def call : TransferResponse
    from_account = Account.find?(transfer_request.from_account_id)
    raise Errors::NotFound.new("Source account") unless from_account

    to_account = Account.find?(transfer_request.to_account_id)
    raise Errors::NotFound.new("Destination account") unless to_account

    amount = transfer_request.amount
    raise Errors::BadRequest.new("Amount must be positive") if amount <= 0

    if from_account.balance < amount
      raise InsufficientFundsError.new(amount, from_account.balance)
    end

    transfer = Transfer.execute!(from_account, to_account, amount)
    TransferResponse.new(transfer)
  end
end
```

## Error Documentation

Document your errors for API consumers:

```crystal
# Each error code has a specific meaning:
#
# Client Errors:
# - BAD_REQUEST (400): The request was malformed
# - UNAUTHORIZED (401): Authentication is required
# - FORBIDDEN (403): You don't have permission
# - NOT_FOUND (404): The resource doesn't exist
# - VALIDATION_FAILED (422): Input validation failed
#
# Server Errors:
# - INTERNAL_ERROR (500): Something went wrong on our end
# - SERVICE_UNAVAILABLE (503): A dependent service is down
```

## See Also

- [Handle Errors Gracefully](handle-errors-gracefully.md)
