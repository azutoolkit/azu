---
description: See template changes without restarting the server during development.
---

# Enable hot reload

## Enable hot reload

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

{% hint style="warning" %}
`config.templates` is built on first use from `template_hot_reload` and the template path, so set both before the
first render, at boot.
{% endhint %}

## How it works

With hot reload on, at most once per second a template render checks the modification times of the `*.html`,
`*.jinja` and `*.j2` files below the template directories (and Azu's own error pages). When one is new or changed,
Azu rebuilds its template loader, and files that are added or deleted count as changes too. No restart is needed.

With hot reload off, templates are preloaded instead: at boot (`Azu.prepare`) every template below the template
directories is read and parsed once, and a render is a lookup by name. An edited template file is not read again until
the app restarts, and a template with a syntax error stops the boot with its name and line. This is the default in
every environment except `development`, `test` and `pipeline`; `template_hot_reload` (or `TEMPLATE_HOT_RELOAD`) wins
over the environment, so you can turn reload on in staging. Changes to `.cr` files, including the data a response
passes to a template, need a restart in both modes. A file below the template directories that is not a template
(a vendored `index.html`) stops the boot as well; list it in `template_preload_ignore` (see
[Configuration](../../reference/configuration/options.md#templates)).

## Development vs production

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

## Rebuild on code changes

Crystal code changes need a rebuild: `azu dev` from the [azu CLI](https://github.com/azutoolkit/azu_cli) rebuilds and
restarts the app when the code changes.

## Browser auto-refresh

Reload the page when a template changes with a small development-only channel. A background fiber polls the
template files and broadcasts to every connected browser through `Azu::PubSub`:

```crystal
class LiveReloadChannel < Azu::Channel
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

if Azu::CONFIG.env.development?
  LiveReloadChannel.ws "/livereload"
  LiveReloadChannel.watch("./public/templates")
end
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

The channel writes every broadcast to the socket as it is, so the browser receives the string `reload`.

{% hint style="warning" %}
Register the channel only in development: a channel exposes a route in every environment.
{% endhint %}

## Troubleshooting

### Changes not reflecting

1. Check that the template path is the directory you are editing. The default path is relative to the working
   directory the server was started in (see [Render HTML Templates](render-html-templates.md#template-location)).
2. Check that the file name matches what `view` asks for, including the extension.
3. A change to Crystal code, including the hash passed to `view`, needs a rebuild.

## See also

- [Render HTML Templates](render-html-templates.md)
