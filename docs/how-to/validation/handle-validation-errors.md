# How to Handle Validation Errors

This guide shows you how to handle and respond to validation errors in your Azu application.

## Automatic Error Handling

Azu automatically validates requests and raises `ValidationError` for invalid data:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # If validation fails, Azu raises ValidationError automatically
    # The error handler converts it to a 422 response
    UserResponse.new(User.create!(create_user_request))
  end
end
```

## Default Error Response

When validation fails, Azu returns:

```json
{
  "errors": [
    {"field": "name", "message": "can't be blank"},
    {"field": "email", "message": "is invalid"}
  ]
}
```

With HTTP status `422 Unprocessable Entity`.

## Custom Error Responses

Create a custom error response format:

```crystal
struct ValidationErrorResponse
  include Azu::Response

  def initialize(@errors : Array(Azu::Request::Error))
  end

  def render
    {
      success: false,
      error: {
        code: "VALIDATION_FAILED",
        details: @errors.map do |e|
          {field: e.field.to_s, message: e.message}
        end
      }
    }.to_json
  end
end
```

## Manual Validation Handling

Handle validation manually in your endpoint:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, Azu::Response)

  post "/users"

  def call : Azu::Response
    request = create_user_request

    unless request.valid?
      status 422
      return ValidationErrorResponse.new(request.errors)
    end

    status 201
    UserResponse.new(User.create!(request))
  end
end
```

## Model Validation Errors

Handle model validation errors:

```crystal
def call : Azu::Response
  user = User.new(
    name: create_user_request.name,
    email: create_user_request.email
  )

  if user.save
    status 201
    UserResponse.new(user)
  else
    status 422
    ModelErrorResponse.new(user.errors)
  end
end
```

## Custom Error Handler

Create a global error handler for validation errors:

```crystal
class ValidationErrorHandler < Azu::Handler::Base
  def call(context)
    call_next(context)
  rescue error : Azu::Response::ValidationError
    context.response.status_code = 422
    context.response.content_type = "application/json"
    context.response.print({
      error: "Validation Failed",
      details: error.errors.map { |e| {field: e.field, message: e.message} }
    }.to_json)
  end
end
```

Register the handler:

```crystal
MyApp.start [
  ValidationErrorHandler.new,
  Azu::Handler::Rescuer.new,
  # ... other handlers
]
```

## Collecting All Errors

Ensure all validation errors are collected:

```crystal
struct MultiFieldRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter password : String

  def initialize(@name = "", @email = "", @password = "")
  end

  validate name, presence: true, length: {min: 2}
  validate email, presence: true, format: /@/
  validate password, presence: true, length: {min: 8}

  # All errors are collected, not just the first one
end
```

## Displaying Errors to Users

For HTML responses, pass errors to templates:

```crystal
def call
  request = create_user_request

  unless request.valid?
    return view "users/new.html", {
      errors: request.errors,
      form_data: request
    }
  end

  redirect_to "/users"
end
```

In your template:

```html
{% if errors %}
<div class="errors">
  <ul>
    {% for error in errors %}
    <li>{{ error.field }}: {{ error.message }}</li>
    {% endfor %}
  </ul>
</div>
{% endif %}
```

## Internationalization

Customize error messages:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  def validate
    if name.empty?
      errors << Error.new(:name, I18n.t("errors.name.blank"))
    elsif name.size < 2
      errors << Error.new(:name, I18n.t("errors.name.too_short", min: 2))
    end
  end
end
```

## See Also

- [Validate Requests](validate-requests.md)
- [Validate Models](validate-models.md)
- [Create Custom Errors](../errors/create-custom-errors.md)
