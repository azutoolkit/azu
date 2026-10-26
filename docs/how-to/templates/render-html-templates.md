---
description: Render HTML templates with Azu's Crinja template engine (Jinja2 syntax).
---

# Render HTML templates

## Basic template rendering

A response renders a template: include `Azu::Templates::Renderable` and call `view` with the template name and the
data for it. The data keys become template variables:

```crystal
struct HomeResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def render
    view "home/index.jinja", {
      "title"   => "Welcome",
      "message" => "Hello, World!",
    }
  end
end

struct HomeEndpoint
  include Azu::Endpoint(Azu::Request, HomeResponse)

  get "/"

  def call : HomeResponse
    content_type "text/html"
    HomeResponse.new
  end
end
```

`view` also accepts a `NamedTuple` or any hash of values Crinja understands (strings, numbers, booleans, arrays,
hashes). Without a template name it renders the template named after the response type: `Blog::Posts::ShowPage`
renders `blog/posts/show_page.jinja`.

The [template helpers](../../reference/templates/helpers.md) are always available.

`view` also adds the variables of the request being served: `current_path`, `current_url`, `flash`, `method`,
`referer` and the others listed in the [helpers reference](../../reference/templates/helpers.md#request-variables),
plus `csrf_token`, `csrf_tag` and `csrf_metatag` once the app uses `Azu::Handler::CSRF`. A value you pass in `data`
wins over a request variable of the same name. A page with a form needs nothing more than the helpers:

```jinja
{% if flash.error %}<p class="error">{{ flash.error }}</p>{% endif %}
<form method="post" action="/signup">
  {{ csrf_field() }}
  <input name="email" type="email">
</form>
```

Outside a request (a background job rendering an email) there are no request variables, and `flash` is empty. To
render with a request you hold yourself, for example in a custom handler, use
`view_with_context(template, context, data)`.

## Template location

Azu looks for templates in the directories of `config.templates.path`.

{% hint style="warning" %}
**The default is a path relative to the working directory the server runs in, not to your project**, so set it
explicitly.
{% endhint %}

Applications generated with `azu new` keep templates in `public/templates`:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.templates.path = "./public/templates"
  end
end
```

`path=` adds a directory to the search path; `TEMPLATES_PATH` (comma separated) sets the whole list from the
environment. Templates are found by their path below the directory:

```text
public/templates/
├── layouts/
│   └── application.jinja
├── home/
│   └── index.jinja
├── users/
│   ├── index.jinja
│   ├── show.jinja
│   └── edit.jinja
└── shared/
    ├── _header.jinja
    └── _footer.jinja
```

Use the `.jinja`, `.j2` or `.html` extension: those are the files hot reload watches
(see [Enable Hot Reload](enable-hot-reload.md)). Azu's error pages (`error.html`, `error_debug.html`) are compiled into the binary, so they are found from any working directory. They are searched last: an `error.html` in your own template directory (or in `ERROR_TEMPLATE`) replaces the built-in page.

A template that cannot be found raises `Crinja::TemplateNotFoundError`.

## Template syntax

Crinja uses Jinja2-style syntax:

```html
<!-- public/templates/home/index.jinja -->
<!DOCTYPE html>
<html>
<head>
  <title>{{ title }}</title>
</head>
<body>
  <h1>{{ message }}</h1>

  {% if user %}
    <p>Welcome, {{ user.name }}!</p>
  {% else %}
    <p>Please log in.</p>
  {% endif %}
</body>
</html>
```

Output is autoescaped in every template: `.html`, `.jinja`, `.j2` and templates rendered from a string. `{{ user.name }}`
with `<script>` in the name prints `&lt;script&gt;`. A value that really is markup is marked with `{{ markup | safe }}`
(or the `safe_html` filter); the built-in helpers (`link_to`, `form_tag`, `csrf_field`, ...) return markup that is
already safe and are not escaped again. Templates of other formats (`mail.txt`, `mail.txt.jinja`, `data.json.jinja`, and `js`, `css`, `csv`, `md`,
`yml`, `sql`, `sh`) are not escaped; `xml`, `rss`, `atom` and `svg` are. `{% autoescape false %}...{% endautoescape %}`
turns it off for a block. Filters such as `upper`, `truncate`, `replace` and the `~` operator return plain text, so
markup that went through them is escaped: apply `| safe` last.
`{{ value | e }}` does not escape twice. To turn the escaping of `.jinja`/`.j2` off for an app, set
`template_autoescape = false` or `TEMPLATE_AUTOESCAPE=false` (see [Configuration](../../reference/configuration/options.md#templates)).

## Variables

Pass data to templates. Build plain values (hashes, arrays, strings) from your models:

```crystal
struct UserPageResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@name : String, @email : String, @titles : Array(String), @admin : Bool)
  end

  def render
    view "users/show.jinja", {
      "user"     => {"name" => @name, "email" => @email},
      "posts"    => @titles.map { |title| {"title" => title} },
      "is_admin" => @admin,
    }
  end
end
```

Access in the template:

```html
<h1>{{ user.name }}</h1>
<p>Email: {{ user.email }}</p>

{% if is_admin %}
  <a href="/admin">Admin Panel</a>
{% endif %}

<h2>Recent Posts</h2>
<ul>
{% for post in posts %}
  <li>{{ post.title }}</li>
{% endfor %}
</ul>
```

## Loops

Iterate over collections:

```html
{% for item in items %}
  <div class="item">
    <span>{{ loop.index }}.</span>
    <span>{{ item.name }}</span>
  </div>
{% else %}
  <p>No items found.</p>
{% endfor %}
```

Loop variables:
- `loop.index` - Current iteration (1-indexed)
- `loop.index0` - Current iteration (0-indexed)
- `loop.first` - True on first iteration
- `loop.last` - True on last iteration
- `loop.length` - Total number of items

## Conditionals

```html
{% if user.role == "admin" %}
  <span class="badge">Admin</span>
{% elif user.role == "moderator" %}
  <span class="badge">Moderator</span>
{% else %}
  <span class="badge">User</span>
{% endif %}
```

## Filters

Transform values with filters:

```html
{{ name | upper }}
{{ description | truncate(100) }}
{{ price | round(2) }}
{{ created_at | date_format("%Y-%m-%d") }}
{{ content | escape }}
{{ list | join(", ") }}
{{ text | default("N/A") }}
```

`date_format` is an Azu helper; see the [helper reference](../../reference/templates/helpers.md) for the others
(`currency`, `time_ago`, `l`, ...).

## Layouts

Create a base layout:

```html
<!-- public/templates/layouts/application.jinja -->
<!DOCTYPE html>
<html>
<head>
  <title>{% block title %}My App{% endblock %}</title>
</head>
<body>
  <header>
    {% include "shared/_header.jinja" %}
  </header>

  <main>
    {% block content %}{% endblock %}
  </main>

  <footer>
    {% include "shared/_footer.jinja" %}
  </footer>
</body>
</html>
```

Extend the layout:

```html
<!-- public/templates/users/index.jinja -->
{% extends "layouts/application.jinja" %}

{% block title %}Users - My App{% endblock %}

{% block content %}
<h1>Users</h1>
<ul>
{% for user in users %}
  <li>{{ user.name }}</li>
{% endfor %}
</ul>
{% endblock %}
```

## Partials

Include reusable components. An included template sees the variables of the template that includes it:

```html
<!-- public/templates/shared/_user_card.jinja -->
<div class="user-card">
  <h3>{{ user.name }}</h3>
  <p>{{ user.bio }}</p>
</div>
```

```html
{% for user in users %}
  {% include "shared/_user_card.jinja" %}
{% endfor %}
```

## Macros

Define reusable template functions:

```html
{% macro input(name, value="", type="text") %}
<input type="{{ type }}" name="{{ name }}" value="{{ value }}" class="form-input">
{% endmacro %}

{{ input("email", user.email, "email") }}
{{ input("password", type="password") }}
```

## Comments

```html
{# This is a comment and won't be rendered #}
```

## Raw output

Disable template processing:

```html
{% raw %}
  This {{ will not }} be processed
{% endraw %}
```

## Custom helpers

Register your own functions and filters before the first render. They are available in every template:

```crystal
Azu::Helpers.function :format_currency do
  "$#{"%.2f" % arguments["amount"].to_s.to_f}"
end

Azu::Helpers.filter :shout do
  target.to_s.upcase + "!"
end
```

Use in a template:

```html
{{ format_currency(amount=order_total) }}
{{ "hello" | shout }}
```

See [Template helpers](../../reference/templates/helpers.md).

## See also

- [Enable Hot Reload](enable-hot-reload.md)
- [Template helpers reference](../../reference/templates/helpers.md)
