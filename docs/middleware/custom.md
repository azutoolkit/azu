# Custom Middleware

Azu allows you to implement custom middleware handlers to extend or modify the request/response lifecycle.

## Summary

Custom middleware enables:

- Custom authentication/authorization
- Request/response transformation
- Custom logging or metrics
- Integration with external services

## Implementing Custom Middleware

Custom middleware must implement the `Azu::Handler` interface:

```crystal
class MyCustomHandler < Azu::Handler
  def call(request, response)
    # Pre-processing
    Log.info { "Custom handler before endpoint" }

    call_next(request, response)

    # Post-processing
    Log.info { "Custom handler after endpoint" }
  end
end
```

## Registering Middleware

```crystal
ExampleApp.start [
  MyCustomHandler.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Static.new
]
```

## Next Steps

- [Built-in Handlers](built-in.md)
- [Error Handling](errors.md)
- [API Reference: Handlers](../api-reference/handlers.md)
