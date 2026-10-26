---
description: Translate pages and messages into several languages and serve each visitor in the one their browser asks for.
---

# Localize your app

Translations live in YAML files, one top-level key per locale. `Azu::Handler::Locale` picks the locale of each
request from its `Accept-Language` header, and the `t` and `l` template helpers read the files in that locale.

Before you start: an app whose responses render templates with `view` (see
[Render HTML templates](render-html-templates.md)).

## Write the locale files

Put one file per language in a `locales` directory at the root of the project:

{% code title="locales/en.yml" %}
```yaml
en:
  home:
    title: "Welcome"
    greeting: "Hello, %{name}!"
  inbox:
    count:
      zero: "No messages"
      one: "1 message"
      other: "%{count} messages"
  date:
    long: "%B %-d, %Y"
  number:
    delimiter: ","
    separator: "."
```
{% endcode %}

{% code title="locales/es.yml" %}
```yaml
es:
  home:
    title: "Bienvenido"
    greeting: "¡Hola, %{name}!"
  inbox:
    count:
      zero: "No hay mensajes"
      one: "1 mensaje"
      other: "%{count} mensajes"
  date:
    long: "%d/%m/%Y"
  number:
    delimiter: "."
    separator: ","
```
{% endcode %}

- Nested keys are joined with dots: `home.title`, `inbox.count`.
- `%{name}` is filled from the arguments of `t`.
- A key whose children are `zero`, `one` and `other` is a plural: `count` 0 picks `zero` (or `other` without
  it), 1 picks `one`, any other number `other`. No other plural category is ever picked: for languages with
  more forms (`few`, `many`), give each form a key of its own and choose it in your code.
- Every `.yml`, `.yaml` and `.json` file below the directory is read, so you can also split the files by feature
  (`locales/es/inbox.yml`). A file that does not parse is skipped with a warning in the log.
- A key missing in `es` is looked up in `fallback_locale` when one is set, then in the default locale, so the page
  shows the English text instead of a gap.

## Configure the locales

<!-- prelude -->
```crystal
module MyApp
  include Azu

  configure do |config|
    config.i18n.load_path = ["locales"]
    config.i18n.default_locale = "en"
    config.i18n.available_locales = ["en", "es"]
  end
end
```

`load_path` is relative to the directory the server runs in. `available_locales` is the list the locale of a
request is picked from: a language left out of it is never picked, even when its file exists. Each setting can come
from an `I18N_*` variable instead (see the [i18n options](../../reference/configuration/options.md#i18n)).

The settings are handed to `Azu::Helpers::I18n` when the app builds its handler chain: in `MyApp.start`, or when a
spec builds an `Azu::Testing::Client`.

{% hint style="warning" %}
A `load_path` none of whose directories exists at that moment is ignored, and translations are read from
`locales` instead. Start the server from the project root, or give an absolute path.
{% endhint %}

## Pick the locale for each request

Add `Azu::Handler::Locale` to the handlers:

```crystal
MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Locale.new,
] of HTTP::Handler
```

A browser that sends `Accept-Language: es-MX,es;q=0.9,en;q=0.8` is served in `es`, and one that asks only for
`de` in the default locale, `en`. The [matching rules](../../reference/handlers/built-in.md#handlerlocale) are in
the reference. The locale holds for everything the request does and ends with it.

`Handler::Locale` sets no `Vary: Accept-Language` or `Content-Language` header. If a shared cache sits in front of
the app, set them in your endpoints, or one language is served to everybody.

To let a visitor choose, store the choice in a cookie and apply it after `Handler::Locale`:

```crystal
class LocaleCookie
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    chosen = context.request.cookies["locale"]?.try(&.value)
    if chosen && Azu::Helpers::I18n.available_locales.includes?(chosen)
      Azu::Helpers::I18n.with_locale(chosen) { call_next(context) }
    else
      call_next(context)
    end
  end
end
```

With `LocaleCookie.new` after `Azu::Handler::Locale.new` in the list, a request with the cookie `locale=es` is served
in Spanish whatever its `Accept-Language`, and a cookie naming a locale you do not offer is ignored.

## Translate in templates

{% code title="home.jinja" %}
```jinja
<html lang="{{ current_locale() }}">
<h1>{{ t("home.title") }}</h1>
<p>{{ t("home.greeting", name=name) }}</p>
<p>{{ t("inbox.count", count=unread) }}</p>
<p>{{ joined | l("date.long") }}</p>
<p>{{ balance | number_with_delimiter(delimiter=t("number.delimiter"), separator=t("number.separator")) }}</p>
</html>
```
{% endcode %}

<!-- prelude -->
```crystal
struct HomePage
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@name : String, @unread : Int32, @joined : Time, @balance : Float64)
  end

  def render
    view "home.jinja", {"name" => @name, "unread" => @unread, "joined" => @joined, "balance" => @balance}
  end
end

struct HomeEndpoint
  include Azu::Endpoint(Azu::Request, HomePage)

  get "/"

  def call : HomePage
    content_type "text/html"
    HomePage.new("Ada", 3, Time.utc(2024, 1, 15), 1234567.5)
  end
end
```

`GET /` with `Accept-Language: es` renders:

```html
<html lang="es">
<h1>Bienvenido</h1>
<p>¡Hola, Ada!</p>
<p>3 mensajes</p>
<p>15/01/2024</p>
<p>1.234.567,5</p>
</html>
```

and without the header:

```html
<html lang="en">
<h1>Welcome</h1>
<p>Hello, Ada!</p>
<p>3 messages</p>
<p>January 15, 2024</p>
<p>1,234,567.5</p>
</html>
```

- `t("key", name=...)` fills `%{name}`; `count=` picks the plural and fills `%{count}`; `default="..."` is printed
  when the key is missing in every locale. A missing key without a default prints `[missing: home.titel]`, or
  raises when `raise_on_missing` is on.
- `pluralize(count=n, singular="item")` only picks between two English words (`item` or `items`); use `t` with
  `count=` for text that is translated.
- `available_locales()` and the `locale_name` filter list the languages for a menu; with the configuration above
  this prints `English` and `Spanish`:

```jinja
{% for locale in available_locales() %}<li lang="{{ locale }}">{{ locale | locale_name }}</li>{% endfor %}
```

## Translate in Crystal code

`Azu::Helpers::I18n.t` reads the same files, in the locale of the request being served (`en` here):

```crystal
Azu::Helpers::I18n.t("home.greeting", name: "Ada")              # => "Hello, Ada!"
Azu::Helpers::I18n.t("inbox.count", count: 7)                   # => "7 messages"
Azu::Helpers::I18n.t("home.greeting", locale: "es", name: "Ada") # => "¡Hola, Ada!"
Azu::Helpers::I18n.exists?("home.title", "es")                  # => true
```

Outside a request, in a background job or a mailer, the locale is the default one. Pass `locale:`, or wrap the
work so every `t` and every template inside it uses the recipient's language:

```crystal
recipient_locale = "es"

subject = Azu::Helpers::I18n.with_locale(recipient_locale) do
  Azu::Helpers::I18n.t("inbox.count", count: 7)
end
subject # => "7 mensajes"
```

## Format dates and numbers

The `l` filter reads a format from the locale file, `date.long` above, and formats the value with it, in Crystal's
`Time#to_s` patterns. In Crystal code it is `Azu::Helpers::I18n.l(time, "date.long")`, with an optional locale as
the third argument.

{% hint style="warning" %}
Month and day names come from `Time#to_s` and are English in every locale: `%d de %B` prints `15 de January`. Give
other languages numeric formats, or pass names you translated yourself. `l` accepts a `Time`, a Unix timestamp or a
`YYYY-MM-DD` (or `YYYY-MM-DDTHH:MM:SS`) string; any other value is formatted as the current time.
{% endhint %}

Numbers are not localized by `l`. The number filters take their separators as arguments, so keep the separators in
the locale file and pass them, as the template above does. The same works for money:

```jinja
{{ 1234.5 | currency(symbol="€", format="%n %s", delimiter=t("number.delimiter"), separator=t("number.separator")) }}
```

prints `1.234,50 €` in Spanish and `1,234.50 €` in English.

## Test it

Send `Accept-Language` from a spec. Run the spec from the project root, so `locales` resolves:

```crystal
require "spec"
require "azu"
require "azu/testing"

describe HomeEndpoint do
  it "answers in the visitor's language" do
    client = Azu::Testing::Client.new(Azu::App.default, [
      Azu::Handler::RequestId.new,
      Azu::Handler::Rescuer.new,
      Azu::Handler::Locale.new,
    ] of HTTP::Handler)

    client.get("/", headers: {"Accept-Language" => "es-MX,es;q=0.9"}).body.should contain "<h1>Bienvenido</h1>"
    client.get("/", headers: {"Accept-Language" => "de"}).body.should contain "<h1>Welcome</h1>"
  end
end
```

## See also

- [Template helpers: i18n](../../reference/templates/helpers.md#i18n-helpers)
- [Built-in handlers: Locale](../../reference/handlers/built-in.md#handlerlocale)
- [Configuration options: i18n](../../reference/configuration/options.md#i18n)
- [Render HTML templates](render-html-templates.md)
