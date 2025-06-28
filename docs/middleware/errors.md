# Error Handling Middleware

Azu provides robust error handling middleware to catch exceptions, render error pages, and return appropriate status codes.

## Summary

Error handling middleware enables:

- Catching and logging exceptions
- Rendering custom error pages
- Returning proper HTTP status codes
- Aggregating validation errors

## Error Handling Flow

```mermaid
flowchart TD
    Request --> Rescuer
    Rescuer --> Endpoint
    Endpoint --> Error[Exception?]
    Error --> ErrorPage[Render Error Page]
    ErrorPage --> Response
    Endpoint --> Response

    style Rescuer fill:#e8f5e8
    style ErrorPage fill:#fff3e0
```

## Custom Error Pages

You can customize error pages by overriding the default templates in `src/azu/templates/`.

## Next Steps

- [Built-in Handlers](built-in.md)
- [Custom Middleware](custom.md)
- [API Reference: Handlers](../api-reference/handlers.md)
