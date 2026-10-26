---
description: "The syntax of Crinja, Azu's Jinja2-compatible template engine: variables, tags, inheritance, includes, macros, filters, tests and operators."
---

# Template engine

Azu renders templates with [Crinja](https://github.com/straight-shoota/crinja), a Crystal implementation of the
Jinja2 template language; the `crinja` shard is a dependency of Azu and comes with `require "azu"`. This page is the
syntax a `.jinja` template can use. Where templates live, how they are compiled and escaped, and how a response
renders one are on [Templates and Renderable](renderable.md); the filters and functions Azu adds are on
[Template helpers](helpers.md).

```jinja
{% extends "layouts/base.jinja" %}

{% block content %}
<h1>{{ title | upper }}</h1>
{% for item in items %}<li>{{ loop.index }}. {{ item.name }}</li>{% endfor %}
{% endblock %}
```

## Basic syntax

### Variables

Output variables with `{{ }}`:

```html
<h1>{{ title }}</h1>
<p>{{ user.name }}</p>
<p>{{ items[0] }}</p>
```

### Tags

Control flow with `{% %}`:

```html
{% if user %}
  <p>Hello, {{ user.name }}</p>
{% endif %}
```

### Comments

```html
{# This is a comment #}

{#
  Multi-line
  comment
#}
```

## Control structures

### if / elif / else

```html
{% if user.admin %}
  <span class="badge">Admin</span>
{% elif user.moderator %}
  <span class="badge">Moderator</span>
{% else %}
  <span class="badge">User</span>
{% endif %}
```

### for

Loop over collections:

```html
{% for item in items %}
  <li>{{ item.name }}</li>
{% endfor %}

{% for item in items %}
  <li>{{ item }}</li>
{% else %}
  <li>No items found</li>
{% endfor %}
```

**Loop Variables:**

| Variable | Description |
|----------|-------------|
| `loop.index` | Current iteration (1-indexed) |
| `loop.index0` | Current iteration (0-indexed) |
| `loop.first` | True on first iteration |
| `loop.last` | True on last iteration |
| `loop.length` | Total number of items |
| `loop.revindex` | Iterations until end (1-indexed) |

```html
{% for user in users %}
  <tr class="{% if loop.first %}first{% endif %}">
    <td>{{ loop.index }}</td>
    <td>{{ user.name }}</td>
  </tr>
{% endfor %}
```

### for with conditions

```html
{% for user in users if user.active %}
  <li>{{ user.name }}</li>
{% endfor %}
```

## Template inheritance

### extends

Extend a base template:

```html
{% extends "layouts/base.jinja" %}
```

### block

Define overridable blocks:

{% code title="layouts/base.jinja" %}
```html
<!-- layouts/base.jinja -->
<!DOCTYPE html>
<html>
<head>
  <title>{% block title %}Default Title{% endblock %}</title>
</head>
<body>
  {% block content %}{% endblock %}
</body>
</html>
```
{% endcode %}

{% code title="pages/home.jinja" %}
```html
<!-- pages/home.jinja -->
{% extends "layouts/base.jinja" %}

{% block title %}Home Page{% endblock %}

{% block content %}
<h1>Welcome!</h1>
{% endblock %}
```
{% endcode %}

### super

Access parent block content:

```html
{% block content %}
{{ super() }}
<p>Additional content</p>
{% endblock %}
```

## Includes

### include

Include another template:

```html
{% include "partials/header.jinja" %}
{% include "partials/footer.jinja" %}
```

### include with context

An included template sees the variables of the template that includes it. `include` takes `with context` (the
default) or `without context`, and no `name=value` pairs. To pass a value under another name, wrap the include in
a `with` block:

```html
{% include "partials/footer.jinja" without context %}
{% with user=current_user, index=loop.index %}
  {% include "partials/user_card.jinja" %}
{% endwith %}
```

### include with ignore missing

```html
{% include "partials/optional.jinja" ignore missing %}
```

## Macros

### Define macros

```html
{% macro input(name, value="", type="text") %}
<input type="{{ type }}" name="{{ name }}" value="{{ value }}" class="form-input">
{% endmacro %}
```

### Use macros

```html
{{ input("username") }}
{{ input("email", user.email, "email") }}
{{ input("password", type="password") }}
```

### Import macros

```html
{% import "macros/forms.jinja" as forms %}
{{ forms.input("name") }}
```

## Filters

Filters transform values:

```html
{{ name | upper }}
{{ name | lower }}
{{ name | capitalize }}
{{ name | title }}
```

### String filters

| Filter | Description | Example |
|--------|-------------|---------|
| `upper` | Uppercase | `{{ "hello" | upper }}` → `HELLO` |
| `lower` | Lowercase | `{{ "HELLO" | lower }}` → `hello` |
| `capitalize` | Capitalize first | `{{ "hello" | capitalize }}` → `Hello` |
| `title` | Title case | `{{ "hello world" | title }}` → `Hello World` |
| `trim` | Remove whitespace | `{{ " hello " | trim }}` → `hello` |
| `truncate(n)` | Truncate to n chars | `{{ text | truncate(50) }}` |
| `replace(a, b)` | Replace substring | `{{ name | replace(" ", "-") }}` |
| `striptags` | Remove HTML tags | `{{ html | striptags }}` |

### Number filters

| Filter | Description | Example |
|--------|-------------|---------|
| `abs` | Absolute value | `{{ -5 | abs }}` → `5` |
| `round` | Round number | `{{ 3.7 | round }}` → `4` |
| `round(n)` | Round to n decimals | `{{ 3.14159 | round(2) }}` → `3.14` |

### List filters

| Filter | Description | Example |
|--------|-------------|---------|
| `length` | Get length | `{{ items | length }}` |
| `first` | First item | `{{ items | first }}` |
| `last` | Last item | `{{ items | last }}` |
| `join(sep)` | Join with separator | `{{ items | join(", ") }}` |
| `sort` | Sort list | `{{ items | sort }}` |
| `reverse` | Reverse list | `{{ items | reverse }}` |

### Escape filters

| Filter | Description |
|--------|-------------|
| `escape` / `e` | HTML escape |
| `safe` | Mark as safe (no escape) |
| `urlencode` | URL encode |

### Default filter

```html
{{ value | default("N/A") }}
{{ user.name | default("Anonymous") }}
```

### Chaining filters

```html
{{ name | trim | lower | truncate(20) }}
```

## Tests

Test values with `is`:

```html
{% if number is even %}
{% if name is defined %}
{% if value is none %}
{% if text is string %}
```

### Available tests

| Test | Description |
|------|-------------|
| `defined` | Variable is defined |
| `undefined` | Variable is undefined |
| `none` | Value is nil |
| `even` | Number is even |
| `odd` | Number is odd |
| `string` | Value is string |
| `number` | Value is number |
| `iterable` | Value is iterable |

{% hint style="warning" %}
There is no `empty` test, and an empty list or string is truthy, so `{% if not items %}` does not catch it. Test
the length: `{% if items | length == 0 %}`.
{% endhint %}

## Operators

### Comparison

```html
{% if age >= 18 %}
{% if status == "active" %}
{% if name != "" %}
```

### Logical

```html
{% if user and user.active %}
{% if admin or moderator %}
{% if not banned %}
```

### Math

```html
{{ price * quantity }}
{{ total / items }}
{{ count + 1 }}
{{ index % 2 }}
```

### String concatenation

```html
{{ first_name ~ " " ~ last_name }}
```

### In operator

```html
{% if "admin" in roles %}
{% if user.id in allowed_ids %}
```

## Whitespace control

Remove whitespace with `-`:

```html
{% for item in items -%}
  {{ item }}
{%- endfor %}
```

## Raw output

Disable processing:

```html
{% raw %}
  This {{ will not }} be processed
{% endraw %}
```

## See also

- [Templates and Renderable](renderable.md)
- [Template helpers](helpers.md)
- [Render HTML templates](../../how-to/templates/render-html-templates.md)
- [Enable hot reload](../../how-to/templates/enable-hot-reload.md)
