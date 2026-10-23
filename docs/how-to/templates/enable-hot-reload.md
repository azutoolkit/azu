# How to Enable Hot Reload

This guide shows you how to see template changes without restarting the server during development.

## Enable Hot Reload

Hot reload is on by default when `CRYSTAL_ENV` is `development`, `test` or `pipeline` and off otherwise
(`TEMPLATE_HOT_RELOAD=true` or `false` overrides it). To set it in code:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.template_hot_reload = config.env.development?
    config.templates.path = "./public/templates"
  end
end
```

`config.templates` is built on first use from `template_hot_reload` and the template path, so set both before the
first render, at boot.

## How It Works

With hot reload on, at most once per second a template render checks the modification times of the `*.html`,
`*.jinja` and `*.j2` files below the template directories (and Azu's own error pages). When one is new or changed,
Azu rebuilds its template loader, and files that are added or deleted count as changes too. No restart is needed.

In this version of Azu the effect is small, because templates are not cached to begin with: Crinja reads the file again
on every render, so an edited template shows its new content on the next request whether hot reload is on or
off (this was checked with the flag in both positions). Only compiled code needs a restart: changes to `.cr` files,
including the data a response passes to a template.

Do not rely on the flag in production for performance: nothing is cached there either.

## Development vs Production

```crystal
module MyApp
  include Azu

  configure do |config|
    case config.env
    when .production?
      config.template_hot_reload = false
    else
      config.template_hot_reload = true
    end
  end
end
```

## File Watching

To restart the server when Crystal code changes, use a file watcher.

### Using Watchexec

```bash
# Install watchexec
brew install watchexec  # macOS
# or
cargo install watchexec-cli

# Restart when Crystal code changes; template edits need no restart
watchexec -r -e cr crystal run src/app.cr
```

### Using entr

```bash
# Install entr
brew install entr  # macOS

# Watch and restart
find src -name "*.cr" | entr -r crystal run src/app.cr
```

Azu CLI applications have `azu serve` for the same purpose.

## Browser Auto-Refresh

Reload the page when a template changes with a small development-only channel. A background fiber polls the
template files and broadcasts to every connected browser through `Azu::PubSub`:

```crystal
class LiveReloadChannel < Azu::Channel
  ws "/livereload"

  def on_connect
    subscribe "livereload"
  end

  def on_message(message : String)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end

  # Broadcasts "reload" whenever a template file changes
  def self.watch(directory : String, interval : Time::Span = 500.milliseconds) : Nil
    spawn(name: "livereload") do
      seen = latest_change(directory)
      loop do
        sleep interval
        current = latest_change(directory)
        next if current == seen
        seen = current
        Azu::PubSub.broadcast("livereload", "reload")
      end
    end
  end

  private def self.latest_change(directory : String) : Time
    Dir.glob(File.join(directory, "**", "*.{html,jinja,j2}")).max_of? { |file| File.info(file).modification_time } || Time::UNIX_EPOCH
  end
end

LiveReloadChannel.watch("./public/templates") if Azu::CONFIG.env.development?
```

Client-side script, included in your layout in development only:

```html
<script>
  if (location.hostname === 'localhost') {
    const ws = new WebSocket('ws://localhost:4000/livereload');
    ws.onmessage = (e) => {
      if (e.data === 'reload') location.reload();
    };
  }
</script>
```

The channel writes every broadcast to the socket as it is, so the browser receives the string `reload`. Register the
channel only in development: a channel exposes a route in every environment.

## Sentry for Crystal

Sentry rebuilds and restarts the app when files change:

```yaml
# .sentry.yml
info: true
src: src
output_name: app
watch:
  - ./src/**/*.cr
run: ./app
build: crystal build src/app.cr -o app
```

```bash
sentry
```

## Troubleshooting

### Changes Not Reflecting

1. Check that the template path is the directory you are editing. The default path is relative to the working
   directory the server was started in (see [Render HTML Templates](render-html-templates.md#template-location)).
2. Check that the file name matches what `view` asks for, including the extension.
3. A change to Crystal code, including the hash passed to `view`, needs a rebuild.

### Slow Performance

1. Reduce the number of watched files.
2. Use a more specific watch pattern.
3. Use browser caching for assets.

## See Also

- [Render HTML Templates](render-html-templates.md)
