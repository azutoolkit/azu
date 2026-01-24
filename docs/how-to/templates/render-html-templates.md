# How to Render HTML Templates

This guide shows you how to render HTML templates using Azu's Crinja template engine.

## Basic Template Rendering

Create an endpoint that renders a template:

```crystal
struct HomeEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Html)
  include Azu::Templates::Renderable

  get "/"

  def call
    view "home/index.html", {
      title: "Welcome",
      message: "Hello, World!"
    }
  end
end
```

## Template Location

Templates are stored in the `views` directory by default:

```
views/
├── layouts/
│   └── application.html
├── home/
│   └── index.html
├── users/
│   ├── index.html
│   ├── show.html
│   └── edit.html
└── shared/
    ├── _header.html
    └── _footer.html
```

## Template Syntax

Crinja uses Jinja2-style syntax:

```html
<!-- views/home/index.html -->
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

## Variables

Pass data to templates:

```crystal
def call
  view "users/show.html", {
    user: User.find(params["id"]),
    posts: user.posts.recent.all,
    is_admin: current_user.admin?
  }
end
```

Access in template:

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
{% if user.admin %}
  <span class="badge">Admin</span>
{% elif user.moderator %}
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
{{ created_at | date("%Y-%m-%d") }}
{{ content | escape }}
{{ list | join(", ") }}
{{ text | default("N/A") }}
```

## Layouts

Create a base layout:

```html
<!-- views/layouts/application.html -->
<!DOCTYPE html>
<html>
<head>
  <title>{% block title %}My App{% endblock %}</title>
  <link rel="stylesheet" href="/css/app.css">
</head>
<body>
  <header>
    {% include "shared/_header.html" %}
  </header>

  <main>
    {% block content %}{% endblock %}
  </main>

  <footer>
    {% include "shared/_footer.html" %}
  </footer>
</body>
</html>
```

Extend the layout:

```html
<!-- views/users/index.html -->
{% extends "layouts/application.html" %}

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

Include reusable components:

```html
<!-- views/shared/_user_card.html -->
<div class="user-card">
  <img src="{{ user.avatar_url }}" alt="{{ user.name }}">
  <h3>{{ user.name }}</h3>
  <p>{{ user.bio }}</p>
</div>
```

Use the partial:

```html
{% for user in users %}
  {% include "shared/_user_card.html" with user=user %}
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

{#
  Multi-line
  comment
#}
```

## Raw Output

Disable template processing:

```html
{% raw %}
  This {{ will not }} be processed
{% endraw %}
```

## Custom Helpers

Add custom template functions:

```crystal
Azu::Templates.register_function("format_currency") do |args|
  amount = args[0].as_f
  "$#{sprintf("%.2f", amount)}"
end
```

Use in template:

```html
{{ format_currency(order.total) }}
```

## See Also

- [Enable Hot Reload](enable-hot-reload.md)
