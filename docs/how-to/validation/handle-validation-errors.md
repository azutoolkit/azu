---
description: Handle and respond to validation errors in your Azu application.
---

# Handle validation errors

## Automatic error handling

Azu validates the request contract before your endpoint runs. A request that breaks it never reaches `call`: the
endpoint answers it itself with a `422` that lists the failing fields:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true, message: "can't be blank"
  validate email, match: /@/, message: "is invalid"
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
    # If validation fails, call never runs: the request is answered with 422.
    UserResponse.new(create_user_request.name)
  end
end
```

A body that cannot be parsed into the request type at all (for example a missing field that has no default) is
answered with `400` instead.

## Default error response

When validation fails, the status is `422 Unprocessable Entity` and the format of the body follows the first entry of
the request's `Accept` header. A client that asks for JSON gets a problem document, sent as `application/problem+json`
when it names that type and as `application/json` otherwise:

```json
{
  "type": "about:blank",
  "title": "Validation Error",
  "status": 422,
  "detail": "The request could not be processed due to validation errors.",
  "errors": {
    "name": ["can't be blank"],
    "email": ["is invalid"]
  },
  "instance": "/users"
}
```

`text/html` gets an HTML page and an XML type gets XML. A request without `Accept`, or with `*/*` (curl's default),
gets a `text/plain` body.

`config.error_format = Azu::ErrorFormat::Legacy` selects the legacy body (`FieldErrors`, `ErrorId`, `Fingerprint`, ...)
instead; see [Migrate to 0.6](../migrate-to-0.6.md#contracts-answer-422).

## Custom error responses

Create a custom error response format by building it from the `Schema::Error`s of a request. A request that breaks
its contract always gets the body above, so return a response like this one from an endpoint that validates by hand
(see the next section):

```crystal
struct ValidationErrorResponse
  include Azu::Response

  def initialize(@errors : Array(Schema::Error))
  end

  def render
    {
      success: false,
      error:   {
        code:    "VALIDATION_FAILED",
        details: @errors.map do |e|
          {field: e.field.to_s, message: e.message}
        end,
      },
    }.to_json
  end
end
```

## Manual validation handling

An endpoint whose request type has validations never runs for invalid input, so an endpoint that answers invalid
input itself (for example by showing a form again) declares the bare `Azu::Request` and validates a form object
by hand. Give the fields defaults so a missing one does not answer `400`.

```crystal
struct SignupForm
  include Azu::Request

  getter name : String = ""
  getter email : String = ""

  validate name, presence: true, message: "can't be blank"
  validate email, match: /@/, message: "is invalid"
end

struct SignupResult
  include Azu::Response

  def initialize(@errors : Array(Schema::Error))
  end

  def render
    {success: @errors.empty?, errors: @errors.map { |e| "#{e.field}: #{e.message}" }}.to_json
  end
end

struct SignupEndpoint
  include Azu::Endpoint(Azu::Request, SignupResult)

  post "/signup"

  def call : SignupResult
    form = SignupForm.from_www_form(params.to_query)

    status 422 unless form.valid?
    SignupResult.new(form.errors)
  end
end
```

## Domain errors

Failures that only the application can detect, such as a duplicate email, are raised as a `ValidationError` too, so
clients get the same body:

```crystal
struct EmailTakenEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  post "/register"

  def call : Azu::Response::Empty
    email = params["email"]
    raise Azu::Response::ValidationError.new("email", "has already been taken") if email == "ada@example.com"

    status 201
    Azu::Response::Empty.new
  end
end
```

A `Hash(String, Array(String))` of field errors works as well:
`Azu::Response::ValidationError.new({"email" => ["is invalid"]})`.

## Custom error handler

A handler sees only the errors raised inside `call`, such as the domain error above. A request that breaks its
contract never reaches `call`: the endpoint answers it itself, with `400` when the body or a field cannot be read as the
contract's types and `422` with the failing fields when a validation rule fails. A handler that rescues
`Azu::Response::ValidationError` never sees those; it sees only the final status code on the way out. To answer
contract failures in your own format, validate by hand as in [Manual Validation Handling](#manual-validation-handling).

This handler answers the `ValidationError`s raised inside `call` in its own format. `Rescuer` also rescues
`ValidationError`, so the handler goes after it in the list (closer to the router):

```crystal
class ValidationErrorHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    call_next(context)
  rescue error : Azu::Response::ValidationError
    context.response.status_code = 422
    context.response.content_type = "application/json"
    context.response.print({
      error:   "Validation Failed",
      details: error.field_errors,
    }.to_json)
  end
end

module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  ValidationErrorHandler.new,
  # ... other handlers
] of HTTP::Handler
```

With it, `POST /register` with `email=ada@example.com` gets
`{"error":"Validation Failed","details":{"email":["has already been taken"]}}`, while a `POST /users` that breaks
`CreateUserRequest` still gets the problem document above.

## Collecting all errors

Every rule is checked, so all validation errors are collected, not just the first one:

```crystal
struct MultiFieldRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter password : String

  def initialize(@name = "", @email = "", @password = "")
  end

  validate name, presence: true, size: 2..100
  validate email, presence: true, match: /@/
  validate password, presence: true, size: 8..128

  # All errors are collected, not just the first one
end

MultiFieldRequest.new.errors.map(&.field).uniq! # => [:name, :email, :password]
```

## Displaying errors to users

For HTML responses, pass errors to templates. Include `Azu::Templates::Renderable` in the response and call `view`:

```crystal
struct SignupForm
  include Azu::Request

  getter name : String = ""
  getter email : String = ""

  validate name, presence: true, message: "can't be blank"
  validate email, match: /@/, message: "is invalid"
end

struct SignupPageResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@errors : Array(Schema::Error) = [] of Schema::Error)
  end

  def render
    view "users/new.html", {
      "errors" => @errors.map { |error| "#{error.field}: #{error.message}" },
    }
  end
end

struct SignupPageEndpoint
  include Azu::Endpoint(Azu::Request, SignupPageResponse)

  post "/signup/page"

  def call : SignupPageResponse
    form = SignupForm.from_www_form(params.to_query)

    content_type "text/html"
    status 422 unless form.valid?
    SignupPageResponse.new(form.errors)
  end
end
```

In your template:

```html
{% if errors %}
<div class="errors">
  <ul>
    {% for error in errors %}
    <li>{{ error }}</li>
    {% endfor %}
  </ul>
</div>
{% endif %}
```

## Internationalization

Customize error messages with a validator that looks them up in `Azu::Helpers::I18n`:

```crystal
struct LocalizedRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  use LocalizedNameValidator
end

class LocalizedNameValidator < Schema::Validator
  def initialize(@record : LocalizedRequest)
  end

  def valid? : Array(Schema::Error)
    errors = [] of Schema::Error
    name = @record.name

    if name.empty?
      errors << Schema::Error.new(:name, Azu::Helpers::I18n.t("errors.name.blank", default: "can't be blank"))
    elsif name.size < 2
      errors << Schema::Error.new(:name, Azu::Helpers::I18n.t("errors.name.too_short", default: "is too short", min: 2))
    end
    errors
  end
end
```

## See also

- [Validate Requests](validate-requests.md)
- [Database validations](../../reference/database/validations.md)
- [Create Custom Errors](../errors/create-custom-errors.md)
