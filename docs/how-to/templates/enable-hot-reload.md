# How to Enable Hot Reload

This guide shows you how to enable hot reload for templates during development.

## Enable Hot Reload

Configure hot reload in your application:

```crystal
Azu.configure do |config|
  # Enable in development
  if ENV.fetch("AZU_ENV", "development") == "development"
    config.template_hot_reload = true
  end
end
```

## How It Works

When hot reload is enabled:

1. Templates are not cached between requests
2. Changes to template files are reflected immediately
3. No server restart required

Without hot reload:
- Templates are compiled and cached at startup
- Better performance but requires restart for changes

## Development vs Production

```crystal
Azu.configure do |config|
  case ENV.fetch("AZU_ENV", "development")
  when "development"
    config.template_hot_reload = true
    config.log.level = Log::Severity::Debug
  when "production"
    config.template_hot_reload = false
    config.log.level = Log::Severity::Info
  end
end
```

## File Watching

For automatic browser refresh, use a file watcher:

### Using Watchexec

```bash
# Install watchexec
brew install watchexec  # macOS
# or
cargo install watchexec-cli

# Watch for changes and restart
watchexec -r -e cr,html crystal run src/app.cr
```

### Using entr

```bash
# Install entr
brew install entr  # macOS

# Watch and restart
find src views -name "*.cr" -o -name "*.html" | entr -r crystal run src/app.cr
```

## Browser Auto-Refresh

Add LiveReload support:

### Server-Sent Events Approach

```crystal
class LiveReloadChannel < Azu::Channel
  PATH = "/livereload"

  CONNECTIONS = [] of HTTP::WebSocket

  def on_connect
    CONNECTIONS << socket
  end

  def on_close(code, reason)
    CONNECTIONS.delete(socket)
  end

  def self.trigger_reload
    CONNECTIONS.each do |ws|
      ws.send({type: "reload"}.to_json)
    end
  end
end
```

Client-side script:

```html
<script>
  if (location.hostname === 'localhost') {
    const ws = new WebSocket('ws://localhost:4000/livereload');
    ws.onmessage = (e) => {
      const data = JSON.parse(e.data);
      if (data.type === 'reload') {
        location.reload();
      }
    };
  }
</script>
```

### Using LiveReload.js

```html
<!-- Include in development only -->
{% if env == "development" %}
<script src="http://localhost:35729/livereload.js"></script>
{% endif %}
```

Run LiveReload server:

```bash
# Install livereload
npm install -g livereload

# Start watching
livereload views/
```

## Custom Watch Script

Create a development script:

```crystal
# scripts/dev.cr
require "file_utils"

WATCH_DIRS = ["src", "views"]
EXTENSIONS = [".cr", ".html", ".css", ".js"]

def run_server
  Process.new(
    "crystal",
    ["run", "src/app.cr"],
    output: STDOUT,
    error: STDERR
  )
end

def file_changed?(path : String) : Bool
  EXTENSIONS.any? { |ext| path.ends_with?(ext) }
end

server = run_server

loop do
  # Simple polling approach
  sleep 1.second

  changed = false
  WATCH_DIRS.each do |dir|
    Dir.glob("#{dir}/**/*").each do |file|
      if file_changed?(file) && File.info(file).modification_time > 1.second.ago
        changed = true
        break
      end
    end
  end

  if changed
    puts "Change detected, restarting..."
    server.signal(:term)
    server = run_server
  end
end
```

## Sentry for Crystal

Use Sentry for file watching:

```yaml
# shard.yml
development_dependencies:
  sentry:
    github: samueleaton/sentry
```

```yaml
# .sentry.yml
info: true
src: src
output_name: app
watch:
  - ./src/**/*.cr
  - ./views/**/*.html
run: ./app
build: crystal build src/app.cr -o app
```

Run with Sentry:

```bash
sentry
```

## Performance Considerations

Hot reload has overhead:
- Template parsing on every request
- File system access for each template
- Not suitable for production

```crystal
# Always disable in production
if ENV["AZU_ENV"] == "production"
  config.template_hot_reload = false
end
```

## Troubleshooting

### Changes Not Reflecting

1. Check file path matches template lookup
2. Ensure hot reload is enabled
3. Check for template caching in your code

### Slow Performance

1. Reduce number of watched files
2. Use more specific watch patterns
3. Consider using browser caching for assets

## See Also

- [Render HTML Templates](render-html-templates.md)
