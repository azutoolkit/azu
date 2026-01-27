# Template Helpers Reference

Azu provides built-in template helpers for common web development tasks like building forms, generating links, formatting dates, and handling internationalization.

## Quick Reference

```jinja
{# Forms #}
{{ form_tag("/users", method="post") }}
  {{ csrf_field() }}
  {{ text_field("user", "name", required=true) }}
  {{ submit_button("Create") }}
{{ end_form() }}

{# Links #}
{{ link_to("Home", "/", class="nav-link") }}
{{ button_to("Delete", "/posts/1", method="delete") }}

{# Assets #}
{{ stylesheet_tag("app.css") }}
{{ javascript_tag("app.js", defer=true) }}
{{ image_tag("logo.png", alt="Logo") }}

{# i18n #}
{{ t("welcome.title") }}
{{ t("greeting", name=user.name) }}
{{ created_at | l("date.short") }}

{# Numbers #}
{{ price | currency("$") }}
{{ 1234567 | number_with_delimiter }}

{# Dates #}
{{ created_at | time_ago }}
{{ date | date_format("%Y-%m-%d") }}
```

---

## Form Helpers

### form_tag

Opens a form with CSRF protection:

```jinja
{{ form_tag("/users", method="post", class="form") }}
  {# form contents #}
{{ end_form() }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `action` | string | `""` | Form action URL |
| `method` | string | `"post"` | HTTP method (get, post, put, patch, delete) |
| `class` | string | `nil` | CSS class |
| `id` | string | `nil` | Element ID |
| `enctype` | string | `nil` | Form encoding type |
| `multipart` | bool | `false` | Set to true for file uploads |
| `data` | hash | `nil` | Data attributes |
| `onsubmit` | string | `nil` | JavaScript onsubmit handler |

Non-standard methods (put, patch, delete) automatically add a hidden `_method` field.

### end_form

Closes a form tag:

```jinja
{{ end_form() }}
```

### csrf_field

Generates a hidden CSRF token input:

```jinja
{{ csrf_field() }}
{# Output: <input type="hidden" name="_csrf" value="token123..." /> #}
```

### csrf_meta

Generates a CSRF meta tag for JavaScript use:

```jinja
{{ csrf_meta() }}
{# Output: <meta name="csrf-token" content="token123..." /> #}
```

### text_field

Generates a text input:

```jinja
{{ text_field("user", "name", placeholder="Enter name", required=true) }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `object` | string | `""` | Object name (e.g., "user") |
| `attribute` | string | `""` | Attribute name (e.g., "name") |
| `value` | any | `nil` | Input value |
| `placeholder` | string | `nil` | Placeholder text |
| `class` | string | `nil` | CSS class |
| `id` | string | `nil` | Override generated ID |
| `required` | bool | `false` | Mark as required |
| `disabled` | bool | `false` | Disable input |
| `readonly` | bool | `false` | Read-only input |
| `autofocus` | bool | `false` | Auto-focus on load |
| `maxlength` | int | `nil` | Maximum length |
| `minlength` | int | `nil` | Minimum length |
| `pattern` | string | `nil` | Validation pattern |
| `data` | hash | `nil` | Data attributes |

### email_field

Generates an email input:

```jinja
{{ email_field("user", "email", required=true) }}
```

### password_field

Generates a password input:

```jinja
{{ password_field("user", "password", minlength=8) }}
```

### number_field

Generates a number input:

```jinja
{{ number_field("product", "quantity", min=1, max=100, step=1) }}
{{ number_field("product", "price", step="0.01") }}
```

Additional parameters: `min`, `max`, `step`

### textarea

Generates a textarea:

```jinja
{{ textarea("post", "content", rows=5, cols=40) }}
```

Additional parameters: `rows`, `cols`

### hidden_field

Generates a hidden input:

```jinja
{{ hidden_field("user", "id", value=user.id) }}
```

### checkbox

Generates a checkbox with hidden unchecked value:

```jinja
{{ checkbox("user", "active", checked=true) }}
{{ checkbox("user", "newsletter", label="Subscribe to newsletter") }}
```

Additional parameters: `checked`, `label`, `unchecked_value` (default "0")

### radio_button

Generates a radio button:

```jinja
{{ radio_button("user", "role", value="admin", label="Administrator") }}
{{ radio_button("user", "role", value="user", label="Regular User", checked=true) }}
```

Additional parameters: `value`, `checked`, `label`

### select_field

Generates a select dropdown:

```jinja
{{ select_field("user", "country", options=[
  {"value": "us", "label": "United States"},
  {"value": "ca", "label": "Canada"},
  {"value": "uk", "label": "United Kingdom"}
], selected="us", include_blank="Select country...") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `options` | array | `[]` | Array of {value, label} objects |
| `selected` | string | `nil` | Pre-selected value |
| `include_blank` | string | `nil` | Blank option text |
| `multiple` | bool | `false` | Allow multiple selection |

### label_tag

Generates a label element:

```jinja
{{ label_tag("user_email", "Email Address") }}
```

### submit_button

Generates a submit button:

```jinja
{{ submit_button("Create Account", class="btn btn-primary") }}
```

---

## URL Helpers

### link_to

Generates an anchor tag:

```jinja
{{ link_to("Home", "/", class="nav-link") }}
{{ link_to("Docs", "/docs", target="_blank") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `text` | string | `""` | Link text |
| `href` | string | `""` | URL |
| `class` | string | `nil` | CSS class |
| `id` | string | `nil` | Element ID |
| `target` | string | `nil` | Target (_blank, _self, etc.) |
| `rel` | string | `nil` | Rel attribute |
| `title` | string | `nil` | Title attribute |
| `data` | hash | `nil` | Data attributes |

Links with `target="_blank"` automatically add `rel="noopener noreferrer"`.

### button_to

Generates a form with a submit button (for non-GET actions):

```jinja
{{ button_to("Delete", "/users/1", method="delete", confirm="Are you sure?") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `text` | string | `""` | Button text |
| `href` | string | `""` | Action URL |
| `method` | string | `"post"` | HTTP method |
| `class` | string | `nil` | CSS class |
| `confirm` | string | `nil` | Confirmation message |
| `disabled` | bool | `false` | Disable button |
| `data` | hash | `nil` | Data attributes |

### mail_to

Generates a mailto link:

```jinja
{{ mail_to("support@example.com", "Contact Us") }}
{{ mail_to("support@example.com", "Email", subject="Hello", body="Message here") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `email` | string | `""` | Email address |
| `text` | string | `nil` | Link text (defaults to email) |
| `subject` | string | `nil` | Email subject |
| `body` | string | `nil` | Email body |
| `cc` | string | `nil` | CC addresses |
| `bcc` | string | `nil` | BCC addresses |
| `class` | string | `nil` | CSS class |
| `id` | string | `nil` | Element ID |

### current_path

Returns the current request path:

```jinja
{{ current_path() }}  {# e.g., "/users" #}
```

### current_url

Returns the full current URL:

```jinja
{{ current_url() }}  {# e.g., "https://example.com/users" #}
```

### is_current_page

Filter that checks if a path matches the current page:

```jinja
{% if "/" | is_current_page %}
  <span class="active">Home</span>
{% endif %}
```

### active_class

Filter that returns a class name if the path is active:

```jinja
<a href="/" class="nav-link {{ '/' | active_class('active') }}">Home</a>
<a href="/about" class="nav-link {{ '/about' | active_class('active', inactive_class='inactive') }}">About</a>
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `class_name` | string | `"active"` | Class to return if active |
| `inactive_class` | string | `""` | Class to return if inactive |
| `exact` | bool | `true` | Exact match vs prefix match |

### back_url

Returns the referer URL or a fallback:

```jinja
{{ link_to("Back", back_url(fallback="/posts")) }}
```

---

## Type-Safe Endpoint Helpers

Azu automatically generates type-safe URL and form helpers from your endpoint definitions. The HTTP method is part of the helper name, making it impossible to confuse which action will be performed.

### How They're Generated

When you define an endpoint with an HTTP method, Azu auto-generates helpers:

```crystal
# Endpoint definition
class UsersEndpoint
  include Azu::Endpoint(UsersRequest, UsersResponse)
  get "/users"
end

class UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)
  get "/users/:id"
end

class CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  post "/users"
end

class UpdateUserEndpoint
  include Azu::Endpoint(UpdateUserRequest, UserResponse)
  put "/users/:id"
end

class DeleteUserEndpoint
  include Azu::Endpoint(DeleteUserRequest, EmptyResponse)
  delete "/users/:id"
end
```

This generates the following helpers:

| Endpoint | Generated Helpers |
|----------|-------------------|
| `UsersEndpoint.get "/users"` | `link_to_get_users()` |
| `UserEndpoint.get "/users/:id"` | `link_to_get_user(id=...)` |
| `CreateUserEndpoint.post "/users"` | `link_to_post_create_user()`, `form_for_post_create_user()` |
| `UpdateUserEndpoint.put "/users/:id"` | `link_to_put_update_user(id=...)`, `form_for_put_update_user(id=...)` |
| `DeleteUserEndpoint.delete "/users/:id"` | `link_to_delete_delete_user(id=...)`, `form_for_delete_delete_user(id=...)`, `button_to_delete_delete_user(id=...)` |

### link_to_{method}_{resource}

Generates anchor tags for any endpoint:

```jinja
{# Collection endpoint (no id parameter) #}
{{ link_to_get_users("View All Users") }}
{# Output: <a href="/users">View All Users</a> #}

{# Member endpoint (with id parameter) #}
{{ link_to_get_user("View User", id="123") }}
{# Output: <a href="/users/123">View User</a> #}

{# Uses path as text when no text provided #}
{{ link_to_get_users() }}
{# Output: <a href="/users">/users</a> #}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `text` | string | path | Link text |
| `id` | string | `nil` | Path parameter value (for `:id` routes) |
| `class` | string | `nil` | CSS class |
| `target` | string | `nil` | Target (_blank, _self, etc.) |
| `data` | hash | `nil` | Data attributes |
| `params` | hash | `nil` | Custom URL query parameters |

**With custom query parameters:**

```jinja
{{ link_to_get_users("Users", params={'page': '2', 'per_page': '10'}) }}
{# Output: <a href="/users?page=2&per_page=10">Users</a> #}

{{ link_to_get_user("View User", id="123", params={'tab': 'profile'}) }}
{# Output: <a href="/users/123?tab=profile">View User</a> #}
```

### form_for_{method}_{resource}

Generates form opening tags for non-GET endpoints. PUT, PATCH, and DELETE methods automatically include a hidden `_method` field:

```jinja
{# POST form #}
{{ form_for_post_create_user(class="user-form") }}
  {{ csrf_field() }}
  {{ text_field("user", "name") }}
  {{ submit_button("Create") }}
{{ end_form() }}
{# Output: <form action="/users" method="post" class="user-form">... #}

{# PUT form (auto-includes _method hidden field) #}
{{ form_for_put_update_user(id="123", class="edit-form") }}
  {{ csrf_field() }}
  {{ text_field("user", "name", value=user.name) }}
  {{ submit_button("Update") }}
{{ end_form() }}
{# Output: <form action="/users/123" method="post" class="edit-form">
     <input type="hidden" name="_method" value="put">... #}

{# DELETE form #}
{{ form_for_delete_delete_user(id="123") }}
  {{ csrf_field() }}
  {{ submit_button("Confirm Delete") }}
{{ end_form() }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `id` | string | `nil` | Path parameter value (for `:id` routes) |
| `class` | string | `nil` | CSS class |
| `enctype` | string | `nil` | Form encoding type |
| `data` | hash | `nil` | Data attributes |
| `params` | hash | `nil` | Custom params as hidden fields |

**With custom hidden fields:**

```jinja
{{ form_for_post_create_user(params={'redirect_to': '/dashboard', 'source': 'signup'}) }}
  {{ csrf_field() }}
  {# generates: <input type="hidden" name="redirect_to" value="/dashboard">
               <input type="hidden" name="source" value="signup"> #}
  {{ text_field("user", "name") }}
  {{ submit_button("Create") }}
{{ end_form() }}
```

### button_to_delete_{resource}

Generates a complete delete form with a submit button (only for DELETE endpoints):

```jinja
{{ button_to_delete_delete_user(id="123") }}
{# Output:
<form action="/users/123" method="post" style="display:inline">
  <input type="hidden" name="_method" value="delete">
  <button type="submit">Delete</button>
</form>
#}

{# With custom text and confirmation #}
{{ button_to_delete_delete_user(text="Remove User", id="123", confirm="Are you sure?") }}
{# Output:
<form action="/users/123" method="post" style="display:inline">
  <input type="hidden" name="_method" value="delete">
  <button type="submit" onclick="return confirm('Are you sure?')">Remove User</button>
</form>
#}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `text` | string | `"Delete"` | Button text |
| `id` | string | `nil` | Path parameter value (for `:id` routes) |
| `class` | string | `nil` | CSS class for the button |
| `confirm` | string | `nil` | JavaScript confirmation message |
| `data` | hash | `nil` | Data attributes |
| `params` | hash | `nil` | Custom params as hidden fields |

**With custom hidden fields:**

```jinja
{{ button_to_delete_delete_user(id="123", params={'redirect': '/users', 'source': 'list'}) }}
{# Generates form with additional hidden fields:
   <input type="hidden" name="redirect" value="/users">
   <input type="hidden" name="source" value="list">
#}
```

### Helper Naming Convention

The helper name is derived from the endpoint class name:

| Class Name | Helper Resource Name |
|------------|---------------------|
| `UsersEndpoint` | `users` |
| `UserEndpoint` | `user` |
| `CreateUserEndpoint` | `create_user` |
| `Admin::UsersEndpoint` | `admin_users` |
| `Api::V1::UserEndpoint` | `api_v1_user` |

### Benefits

1. **Intuitive**: `link_to_get_users` clearly indicates a GET request
2. **Hard to confuse**: The HTTP method is in the name, not a parameter
3. **Type-safe**: Helpers are generated at compile-time from your endpoints
4. **Consistent**: Same pattern works for all endpoints

---

## Asset Helpers

### asset_path

Filter that returns the asset URL:

```jinja
{{ "images/logo.png" | asset_path }}  {# e.g., "/assets/images/logo.png" #}
```

### image_tag

Generates an image element:

```jinja
{{ image_tag("logo.png", alt="Logo", width=200) }}
{{ image_tag("hero.jpg", alt="Hero", class="hero-image", loading="lazy") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `src` | string | `""` | Image source |
| `alt` | string | `""` | Alt text |
| `width` | int | `nil` | Width |
| `height` | int | `nil` | Height |
| `class` | string | `nil` | CSS class |
| `id` | string | `nil` | Element ID |
| `loading` | string | `nil` | Loading strategy (lazy, eager) |

### javascript_tag

Generates a script element:

```jinja
{{ javascript_tag("app.js") }}
{{ javascript_tag("app.js", defer=true) }}
{{ javascript_tag("https://example.com/lib.js", async=true) }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `src` | string | `""` | Script source |
| `defer` | bool | `false` | Defer loading |
| `async` | bool | `false` | Async loading |
| `type` | string | `nil` | Script type |
| `id` | string | `nil` | Element ID |

### stylesheet_tag

Generates a link stylesheet element:

```jinja
{{ stylesheet_tag("app.css") }}
{{ stylesheet_tag("print.css", media="print") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `href` | string | `""` | Stylesheet URL |
| `media` | string | `"all"` | Media type |
| `id` | string | `nil` | Element ID |

### favicon_tag

Generates a favicon link:

```jinja
{{ favicon_tag("favicon.ico") }}
```

---

## Date Helpers

### time_ago

Filter that formats a time as relative past:

```jinja
{{ created_at | time_ago }}  {# e.g., "5 minutes ago", "2 days ago" #}
```

### relative_time

Filter that formats time relative to now (past or future):

```jinja
{{ event_date | relative_time }}  {# e.g., "in 3 days", "2 hours ago" #}
```

### date_format

Filter that formats a date with a strftime pattern:

```jinja
{{ date | date_format }}                    {# January 15, 2024 #}
{{ date | date_format("%Y-%m-%d") }}        {# 2024-01-15 #}
{{ date | date_format("%b %d, %Y") }}       {# Jan 15, 2024 #}
{{ date | date_format("%H:%M:%S") }}        {# 14:30:00 #}
```

### time_tag

Function that generates a time element:

```jinja
{{ time_tag(time=created_at, format="%B %d, %Y") }}
{# Output: <time datetime="2024-01-15T10:30:00Z">January 15, 2024</time> #}
```

### distance_of_time

Filter that converts seconds to human-readable duration:

```jinja
{{ 45 | distance_of_time }}     {# 45 seconds #}
{{ 150 | distance_of_time }}    {# 2 minutes #}
{{ 7200 | distance_of_time }}   {# 2 hours #}
```

---

## Number Helpers

### currency

Filter that formats a number as currency:

```jinja
{{ 1234.5 | currency("$") }}           {# $1,234.50 #}
{{ 1234.5 | currency("€") }}           {# €1,234.50 #}
{{ 1234.567 | currency("$", precision=3) }}  {# $1,234.567 #}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `symbol` | string | `"$"` | Currency symbol |
| `precision` | int | `2` | Decimal places |
| `delimiter` | string | `","` | Thousands delimiter |
| `separator` | string | `"."` | Decimal separator |

### number_with_delimiter

Filter that adds thousands separators:

```jinja
{{ 1234567 | number_with_delimiter }}               {# 1,234,567 #}
{{ 1234567 | number_with_delimiter(delimiter=".") }} {# 1.234.567 #}
```

### percentage

Filter that formats a decimal as percentage:

```jinja
{{ 0.756 | percentage }}            {# 76% #}
{{ 0.756 | percentage(precision=1) }} {# 75.6% #}
```

### filesize

Filter that formats bytes as human-readable:

```jinja
{{ 1024 | filesize }}       {# 1.0 KB #}
{{ 1048576 | filesize }}    {# 1.0 MB #}
{{ 1073741824 | filesize }} {# 1.0 GB #}
```

### number_to_human

Filter that formats large numbers with words:

```jinja
{{ 1234 | number_to_human }}        {# 1.23 thousand #}
{{ 1234567 | number_to_human }}     {# 1.23 million #}
{{ 1234567890 | number_to_human }}  {# 1.23 billion #}
```

---

## HTML Helpers

### safe_html

Filter that marks content as safe (no escaping):

```jinja
{{ html_content | safe_html }}
```

**Warning:** Only use with trusted content to prevent XSS.

### simple_format

Filter that converts newlines to `<br>` and wraps in paragraphs:

```jinja
{{ text | simple_format }}
{{ text | simple_format(tag="div") }}
```

### highlight

Filter that highlights occurrences of a phrase:

```jinja
{{ text | highlight("search term") }}
{# Wraps matches in <mark>...</mark> #}
{{ text | highlight("term", highlighter="<strong>\\0</strong>") }}
```

### truncate_html

Filter that truncates HTML while preserving structure:

```jinja
{{ html_content | truncate_html(100) }}
{{ html_content | truncate_html(100, omission="...") }}
```

### strip_tags

Filter that removes HTML tags:

```jinja
{{ html_content | strip_tags }}
{# "<p>Hello <b>World</b></p>" → "Hello World" #}
```

### word_wrap

Filter that wraps text at a specified width:

```jinja
{{ text | word_wrap(line_width=80) }}
{{ text | word_wrap(line_width=60, break_char="\n") }}
```

### auto_link

Filter that converts URLs and emails to links:

```jinja
{{ text | auto_link }}
{# "Visit https://example.com" → "Visit <a href="...">...</a>" #}
```

### content_tag

Function that generates an HTML tag:

```jinja
{{ content_tag(name="div", content="Hello", class="container") }}
{# <div class="container">Hello</div> #}
```

---

## i18n Helpers

### t (Translate)

Function that translates a key:

```jinja
{{ t("welcome.title") }}
{{ t("greeting", name=user.name) }}
{{ t("users.count", count=5) }}
{{ t("missing.key", default="Fallback text") }}
```

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `key` | string | required | Translation key |
| `default` | string | `nil` | Fallback if key is missing |
| `count` | int | `nil` | For pluralization |
| `**options` | hash | `{}` | Interpolation values |

**Pluralization:**

Define translations with `zero`, `one`, `other` keys:

```yaml
# locales/en.yml
en:
  users:
    count:
      zero: "No users"
      one: "1 user"
      other: "%{count} users"
```

```jinja
{{ t("users.count", count=0) }}  {# No users #}
{{ t("users.count", count=1) }}  {# 1 user #}
{{ t("users.count", count=5) }}  {# 5 users #}
```

### l (Localize)

Filter that localizes dates using translation formats:

```jinja
{{ created_at | l("date.short") }}  {# Jan 15 #}
{{ created_at | l("date.long") }}   {# January 15, 2024 #}
```

### current_locale

Function that returns the current locale:

```jinja
{{ current_locale() }}  {# en #}
```

### available_locales

Function that returns available locales:

```jinja
{% for locale in available_locales() %}
  <a href="?locale={{ locale }}">{{ locale | locale_name }}</a>
{% endfor %}
```

### locale_name

Filter that returns display name for a locale code:

```jinja
{{ "en" | locale_name }}  {# English #}
{{ "es" | locale_name }}  {# Spanish #}
```

### pluralize

Function for simple pluralization:

```jinja
{{ pluralize(count=items.size, singular="item", plural="items") }}
```

---

## Component Helpers

For use with Azu's Spark real-time component system.

### spark_tag

Generates the Spark JavaScript bootstrap:

```jinja
{{ spark_tag() }}
```

### render_component

Renders a Spark live component:

```jinja
{{ render_component("counter", initial_count=0) }}
```

### Live Attribute Filters

Add Spark live attributes to elements:

```jinja
<button {{ "increment" | live_click }}>+</button>
<input type="text" {{ "search" | live_input }}>
<select {{ "update" | live_change }}>...</select>
```

---

## Complete Example

```jinja
{% extends "layouts/application.jinja" %}

{% block title %}{{ t("users.index.title") }}{% endblock %}

{% block content %}
<div class="container">
  <h1>{{ t("users.index.heading") }}</h1>

  {% if flash.notice %}
    <div class="alert alert-success">{{ flash.notice }}</div>
  {% endif %}

  {{ form_tag("/users", method="post", class="user-form") }}
    {{ csrf_field() }}

    <div class="form-group">
      {{ label_tag("user_name", t("users.form.name")) }}
      {{ text_field("user", "name", required=true, class="form-control") }}
    </div>

    <div class="form-group">
      {{ label_tag("user_email", t("users.form.email")) }}
      {{ email_field("user", "email", required=true, class="form-control") }}
    </div>

    {{ submit_button(t("users.form.submit"), class="btn btn-primary") }}
  {{ end_form() }}

  <table class="table">
    <thead>
      <tr>
        <th>{{ t("users.table.name") }}</th>
        <th>{{ t("users.table.created") }}</th>
        <th>{{ t("users.table.actions") }}</th>
      </tr>
    </thead>
    <tbody>
      {% for user in users %}
      <tr>
        <td>{{ user.name }}</td>
        <td>{{ user.created_at | time_ago }}</td>
        <td>
          {{ link_to(t("actions.edit"), "/users/" ~ user.id ~ "/edit", class="btn btn-sm") }}
          {{ button_to(t("actions.delete"), "/users/" ~ user.id, method="delete",
             confirm=t("users.confirm_delete")) }}
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>

  <p>{{ t("users.count", count=users.size) }}</p>
</div>
{% endblock %}
```

## See Also

- [Template Engine](engine.md)
- [How to Render HTML Templates](../../how-to/templates/render-html-templates.md)
- [How to Use Template Helpers](../../how-to/templates/use-template-helpers.md)
