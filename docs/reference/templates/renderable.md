---
description: "How `Azu::Templates` finds, compiles, reloads and escapes templates, and how `Azu::Templates::Renderable#view` renders one with the request's variables."
---

# Templates and Renderable

`Azu::Templates` is the template set of a configuration (`config.templates`): the directories it searches, the Crinja
environment that renders them, and the rules for reloading, compiling and escaping. `Azu::Templates::Renderable` is
the module a response (or an endpoint) includes to render one of them with `view`. Both come with `require "azu"`.
The template syntax is on [Template engine](engine.md), the helpers and request variables on
[Template helpers](helpers.md), and the options that build `config.templates` on
[Configuration options](../configuration/options.md#templates).

```crystal
require "azu"

struct ProfilePage
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@name : String)
  end

  def render
    view "users/profile.jinja", {"name" => @name}
  end
end
```

## API

### Renderable

| Method | Returns | Notes |
| --- | --- | --- |
| `view(template : String = page_path, data = {} of String => Crinja::Value)` | `String` | Private. Renders *template* from `Azu.current_config.templates` with *data* (a `Hash` or `NamedTuple`; keys become variable names) and the [request variables](helpers.md#request-variables) |
| `view_with_context(template : String, http_context : HTTP::Server::Context, data = {} of String => Crinja::Value)` | `String` | Private. Renders with the request variables of a context you hold, for a handler or code outside the request's fiber |
| `page_path` | `String` | The template named after the type: `Blog::Posts::ShowPage` gives `blog/posts/show_page.jinja` |

`view` takes the request from the type's own `context` when it has one (an endpoint), else from
`Azu::RequestContext.current?`, which every endpoint (and `Handler::RequestId`) opens for the request's fiber, so a
response rendered by an endpoint sees the same variables. A key in *data* wins over a request variable of the same name. Outside a request
(a background job, a spec) there are no request variables, and `flash` is an empty hash.

### Templates

`Azu::Templates.new(path, error_path, hot_reload = nil, compile_ignore = [] of String, autoescape = true)`:

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `path` | `Array(String)` | | Directories searched in order; the first that has a name wins |
| `error_path` | `String` | | A directory searched after them, for error pages |
| `hot_reload` | `Bool?` | `nil`: on in `development`, `test` and `pipeline` (from `CRYSTAL_ENV`) | Re-read changed files instead of compiling |
| `compile_ignore` | `Array(String)` | `[]` | Globs of names not compiled at boot |
| `autoescape` | `Bool` | `true` | Escape `{{ }}` output of every template but plain-text formats (see [Escaping](#escaping)) |

`config.templates` builds one from the configuration's options on first use; you rarely build one yourself.

| Method | Returns | Notes |
| --- | --- | --- |
| `load(template : String)` | `Crinja::Template` | The parsed template; raises `Crinja::TemplateNotFoundError` when no directory has it |
| `prepare` | `Nil` | Compiles every template now and raises `Templates::CompileError` for the first that does not parse or a directory that cannot be read. A no-op with hot reload on. `App#start` calls it once the server is bound, before anything else is started |
| `compiled?` | `Bool` | True when hot reload is off |
| `hot_reload=(enabled : Bool)` | | Switches between reloading and compiling; `config.template_hot_reload=` calls it |
| `path` / `path=(path : String)` | `Array(String)` | `path=` **adds** a directory (expanded against the working directory) to the end of the list |
| `error_path` / `error_path=(path : String)` | `String` | Replaces the error directory |
| `compile_ignore` / `compile_ignore=(patterns : Array(String))` | `Array(String)` | `config.template_compile_ignore=` calls the setter |
| `autoescape?` / `autoescape=(enabled : Bool)` | `Bool` | `config.template_autoescape=` calls the setter |
| `crinja` | `Crinja` | The environment, with Azu's helpers applied |
| `builtin(name : String)` | `Crinja::Template` | Azu's own `error.html` or `error_debug.html`, ignoring every directory |

`Templates::CompileError` is a `Crinja::Error`. Its message names the template, its file and Crinja's line:
`template users/show.jinja (/app/templates/users/show.jinja): ...`.

## Behavior

### Finding templates

The directories of `path` are searched in order, then `error_path`, then the built-in error pages. The default
`path` is `../../templates` resolved against the working directory the server starts in, so set
`TEMPLATES_PATH` or call `config.templates.path = "./public/templates"`, and run the app from its root. Azu's own
`error.html` and `error_debug.html` are compiled into the binary, so they are found from any working directory; an
`error.html` in your directories replaces the built-in one. A directory that does not exist is skipped.

### Compiled or reloaded

With hot reload on, `load` checks the files' modification times at most once a second and re-reads what changed.
With it off the templates are **compiled**: `prepare` finds every `*.html`, `*.jinja` and `*.j2` file below the
directories, reads and parses each once, and `load` looks the parsed template up by name. Includes and `extends`
resolve through the same map. Nothing is read from disk per request, so an edit to a template file needs a restart.
A file added after the compile is still found by the file loader. Without `prepare`, the compile happens on the
first `load`.

| Environment (`CRYSTAL_ENV`) | Templates |
|---|---|
| `development` | reloaded (modification time checked at most once a second) |
| `test`, `pipeline` | reloaded, so specs can write templates while running |
| `staging`, `production`, `build`, `integration`, `acceptance` | compiled |
| `template_hot_reload` / `TEMPLATE_HOT_RELOAD` set | wins over the environment, e.g. reload in staging |

The default is read from `CRYSTAL_ENV` when the configuration is built; assigning `config.env = ...` afterwards does
not change it, while assigning `config.template_hot_reload = ...` does, also for templates already built. All
compiled templates stay in memory, and a template mounted from a volume or ConfigMap needs a restart to change.

### Compile errors

A template with a syntax error stops the start with its name and line, instead of failing its first request. An
`error.html` of the app that does not parse is the exception: it is logged and the built-in page is used. Without
`prepare`, a broken template is logged once and left to the file loader, which raises when it is rendered.

Every `*.html`, `*.jinja` and `*.j2` file below the directories is parsed at boot, so a vendored page (a Swagger UI
`index.html`) or a template directory that is really `public/` can stop the boot. `compile_ignore` names what to
skip, with globs on the path relative to a template directory (`*` does not cross `/`, `**` does); the files are
still found when asked for. `TEMPLATE_COMPILE_IGNORE` splits on commas, so brace alternation such as `{a,b}` can only
be written with the Crystal setter. Dot directories and symlinked directories are not walked either; the file loader
serves what is in them.

```crystal
require "azu"

Azu::CONFIG.template_compile_ignore = ["vendor/**", "swagger/*.html"]
```

A directory that cannot be read stops the boot with its name. On a first render without `prepare` it is logged once
and skipped, and because the names inside it are unknown, a valid copy of one of them in a later directory is served
instead. A name that does not parse in one directory is not replaced by a copy in a later directory; `prepare`
validates again even when a first render compiled earlier. A very broad directory such as `.` is scanned whole at
boot, with the count and time logged at debug level.

### Escaping

With `autoescape` on (the default), `{{ }}` output of every template is HTML-escaped, `.jinja`, `.j2` and string
templates included (Crinja alone only escapes `html`, `htm` and `xml`), except templates of plain-text formats:
`txt`, `text`, `json`, `js`, `mjs`, `css`, `csv`, `md`, `markdown`, `yml`, `yaml`, `sql` and `sh`, also as the inner
extension (`mail.txt.jinja`, `data.json.jinja`; `Templates::PLAIN_TEXT_EXTENSIONS`). With it off, Crinja's own rule
applies. `| safe` marks one value as
markup, and `{% autoescape false %}...{% endautoescape %}` turns escaping off for a block. Autoescape is decided at
render time, so it applies to compiled templates too. With it off, `App#start` logs a warning: every `{{ }}` of a
`.jinja` page is then raw HTML.

## Limits

- One `Templates` per configuration; `Azu::Helpers` registrations are process-wide and shared by all of them.
- Only `.html`, `.jinja` and `.j2` files are compiled and watched for changes; a template with another extension is
  read by the file loader when it is asked for.

## See also

- [Render HTML templates](../../how-to/templates/render-html-templates.md)
- [Enable hot reload](../../how-to/templates/enable-hot-reload.md)
- [Template helpers](helpers.md)
- [Template engine](engine.md)
