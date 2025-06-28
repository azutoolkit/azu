# Configuration

Azu provides a flexible, environment-aware configuration system that lets you tailor your application for development, testing, and production. This guide covers all major configuration options, best practices, and real-world examples.

---

## 1. The `configure` Block

Azu applications are configured using a `configure` block inside your main application module:

```crystal
module MyApp
  include Azu

  configure do
    # Configuration options go here
    port = ENV.fetch("PORT", "4000").to_i
    host = ENV.fetch("HOST", "0.0.0.0")
    template_hot_reload = env.development?
  end
end
```

All configuration is available at compile time, ensuring type safety and performance.

---

## 2. Server Settings

- **`host`**: The IP address or hostname to bind the server (default: `0.0.0.0`)
- **`port`**: The port to listen on (default: `4000`)
- **`port_reuse`**: Allow port reuse (default: `false`)

```crystal
configure do
  host = ENV.fetch("HOST", "0.0.0.0")
  port = ENV.fetch("PORT", "4000").to_i
  port_reuse = true
end
```

---

## 3. SSL/TLS Configuration

For production, enable HTTPS with SSL certificates:

```crystal
configure do
  ssl_cert = ENV["SSL_CERT"]?
  ssl_key  = ENV["SSL_KEY"]?
end
```

If both `ssl_cert` and `ssl_key` are set, Azu will start in TLS mode.

---

## 4. Template Engine

- **`templates.path`**: Array of directories to search for templates
- **`template_hot_reload`**: Enable hot reloading in development
- **`templates.error_path`**: Directory for error templates

```crystal
configure do
  templates.path = ["templates", "views"]
  template_hot_reload = env.development?
  templates.error_path = "errors"
end
```

---

## 5. File Uploads

- **`upload.max_file_size`**: Maximum allowed file size (default: `10.megabytes`)
- **`upload.temp_dir`**: Directory for temporary file uploads
- **`upload.allowed_extensions`**: Restrict allowed file extensions
- **`upload.allowed_mime_types`**: Restrict allowed MIME types

```crystal
configure do
  upload.max_file_size = 20.megabytes
  upload.temp_dir = "/tmp/uploads"
  upload.allowed_extensions = [".jpg", ".png", ".pdf"]
  upload.allowed_mime_types = ["image/jpeg", "image/png", "application/pdf"]
end
```

---

## 6. Logging

- **`log.level`**: Set log verbosity (`DEBUG`, `INFO`, `WARN`, `ERROR`)
- **`log`**: Use a custom logger if needed

```crystal
configure do
  log.level = env.production? ? Log::Severity::INFO : Log::Severity::DEBUG
end
```

---

## 7. Environment Detection

Azu automatically detects the environment:

- `Azu::CONFIG.env.development?`
- `Azu::CONFIG.env.production?`
- `Azu::CONFIG.env.test?`

You can set the environment via the `AZU_ENV` environment variable:

```bash
export AZU_ENV=production
```

Or programmatically:

```crystal
Azu::CONFIG.env = Azu::Environment::Production
```

---

## 8. Middleware Stack

Configure the order and presence of middleware in your application:

```crystal
MyApp.start [
  Azu::Handler::RequestId.new,    # Request tracking
  Azu::Handler::Rescuer.new,      # Error handling
  Azu::Handler::Logger.new,       # Logging
  Azu::Handler::CORS.new,         # CORS headers
  Azu::Handler::Static.new("public"), # Static file serving
  # ... your endpoints
]
```

Order matters: place error handlers and loggers early, static/file handlers later.

---

## 9. Advanced: Custom Configuration

You can add your own configuration options by extending the `configure` block:

```crystal
module MyApp
  include Azu

  configure do
    # Custom config
    config.api_key = ENV["API_KEY"]?
    config.feature_flag = ENV["FEATURE_FLAG"]? == "true"
  end
end
```

Access your custom config via `Azu::CONFIG` or your module's `config` method.

---

## 10. Best Practices

- **Use environment variables** for secrets and environment-specific values
- **Enable hot reload** only in development
- **Restrict file uploads** in production
- **Set log level to `INFO` or higher** in production
- **Document all custom configuration**
- **Keep configuration in one place** for maintainability

---

## Example: Production vs. Development

```crystal
configure do
  host = ENV.fetch("HOST", "0.0.0.0")
  port = ENV.fetch("PORT", "4000").to_i
  ssl_cert = ENV["SSL_CERT"]?
  ssl_key  = ENV["SSL_KEY"]?
  templates.path = ["templates"]
  template_hot_reload = env.development?
  upload.max_file_size = env.production? ? 5.megabytes : 50.megabytes
  log.level = env.production? ? Log::Severity::INFO : Log::Severity::DEBUG
end
```

---

## Troubleshooting Configuration

- **Wrong port/host?** Check environment variables and `configure` block.
- **Templates not reloading?** Ensure `template_hot_reload = true` in development.
- **File uploads failing?** Check `upload.max_file_size` and permissions.
- **Logging too verbose?** Set `log.level` appropriately.
- **SSL not working?** Ensure both `ssl_cert` and `ssl_key` are set and readable.

---

## Further Reading

- [Core Concepts](../core-concepts.md)
- [Middleware](../middleware.md)
- [API Reference](../api-reference.md)

---

**Azu's configuration system is designed for clarity, safety, and flexibility. Use it to build robust, environment-aware applications with confidence.**
