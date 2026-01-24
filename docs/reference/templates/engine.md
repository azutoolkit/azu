# Template Engine Reference

Azu uses Crinja, a Jinja2-compatible template engine.

## Basic Syntax

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

## Control Structures

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

## Template Inheritance

### extends

Extend a base template:

```html
{% extends "layouts/base.html" %}
```

### block

Define overridable blocks:

```html
<!-- layouts/base.html -->
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

```html
<!-- pages/home.html -->
{% extends "layouts/base.html" %}

{% block title %}Home Page{% endblock %}

{% block content %}
<h1>Welcome!</h1>
{% endblock %}
```

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
{% include "partials/header.html" %}
{% include "partials/footer.html" %}
```

### include with context

```html
{% include "partials/user_card.html" with user=current_user %}
{% include "partials/item.html" with item=item, index=loop.index %}
```

### include with ignore missing

```html
{% include "partials/optional.html" ignore missing %}
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
{% import "macros/forms.html" as forms %}
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

### String Filters

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

### Number Filters

| Filter | Description | Example |
|--------|-------------|---------|
| `abs` | Absolute value | `{{ -5 | abs }}` → `5` |
| `round` | Round number | `{{ 3.7 | round }}` → `4` |
| `round(n)` | Round to n decimals | `{{ 3.14159 | round(2) }}` → `3.14` |

### List Filters

| Filter | Description | Example |
|--------|-------------|---------|
| `length` | Get length | `{{ items | length }}` |
| `first` | First item | `{{ items | first }}` |
| `last` | Last item | `{{ items | last }}` |
| `join(sep)` | Join with separator | `{{ items | join(", ") }}` |
| `sort` | Sort list | `{{ items | sort }}` |
| `reverse` | Reverse list | `{{ items | reverse }}` |

### Escape Filters

| Filter | Description |
|--------|-------------|
| `escape` / `e` | HTML escape |
| `safe` | Mark as safe (no escape) |
| `urlencode` | URL encode |

### Default Filter

```html
{{ value | default("N/A") }}
{{ user.name | default("Anonymous") }}
```

### Chaining Filters

```html
{{ name | trim | lower | truncate(20) }}
```

## Tests

Test values with `is`:

```html
{% if number is even %}
{% if name is defined %}
{% if items is empty %}
{% if value is none %}
{% if text is string %}
```

### Available Tests

| Test | Description |
|------|-------------|
| `defined` | Variable is defined |
| `undefined` | Variable is undefined |
| `none` | Value is nil |
| `empty` | Collection is empty |
| `even` | Number is even |
| `odd` | Number is odd |
| `string` | Value is string |
| `number` | Value is number |
| `iterable` | Value is iterable |

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

### String Concatenation

```html
{{ first_name ~ " " ~ last_name }}
```

### In Operator

```html
{% if "admin" in roles %}
{% if user.id in allowed_ids %}
```

## Whitespace Control

Remove whitespace with `-`:

```html
{% for item in items -%}
  {{ item }}
{%- endfor %}
```

## Raw Output

Disable processing:

```html
{% raw %}
  This {{ will not }} be processed
{% endraw %}
```

## See Also

- [How to Render HTML Templates](../../how-to/templates/render-html-templates.md)
- [How to Enable Hot Reload](../../how-to/templates/enable-hot-reload.md)
