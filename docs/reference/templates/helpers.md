---
description: "Azu's built-in template helpers: forms, links, endpoint URLs, assets, dates, numbers, HTML and internationalization."
---

# Template helpers

Azu registers these filters and functions on the Crinja environment of every template, with
`Azu::Helpers::Registry`, so a `.jinja` page can call them without an import. They come with `require "azu"`, and
[`Azu::Helpers`](#custom-helpers) adds your own. They are not Crystal methods: endpoints and responses build URLs with
`Endpoint.path` and HTML with `Azu::Markup` instead. How templates are found and rendered is on
[Templates and Renderable](renderable.md).

Renders run concurrently, each with its own variables: a helper you write may do IO, such as a query or an HTTP call,
or render another template, without holding up other requests' renders. A template a helper renders
(`Azu::CONFIG.templates.render(name, data)`, or `view` without a request) starts from the global context: it sees the
globals and the data you pass, not the outer page's variables (`csrf_token`, `current_path`, its view data), so the
fragment can be cached for everyone. Pass what it needs explicitly. `templates.load(name).render(data)` is Crinja's own
render and inherits the current render's variables; helpers should call `render`.

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

## Request variables

While a request is served, `view` gives every template these variables, in an endpoint and in a response (see
[Render HTML templates](../../how-to/templates/render-html-templates.md)). A value passed in `data` wins over a
variable of the same name. Outside a request there are none, and `flash` is empty.

| Variable | Value |
|---|---|
| `current_path` | The request path: `/users/123` |
| `current_url` | Scheme, `Host` header and path with query: `https://example.com/users/123?page=1` |
| `method` | The request method: `GET` |
| `flash` | The flash messages of the session adapter; empty without one |
| `referer` | The `Referer` header, `""` without one |
| `secure` | `true` when `X-Forwarded-Proto` is `https` |
| `ajax` | `true` when `X-Requested-With` is `XMLHttpRequest` |
| `client_ip` | The first address of `X-Forwarded-For`, else `X-Real-IP`, else `""` |
| `accept_locale` | The first language of `Accept-Language`, `en` without one |
| `csrf_token`, `csrf_tag`, `csrf_metatag` | The request's CSRF token, as a value, a hidden `<input>` and a `<meta>` tag. Only once the app uses `Azu::Handler::CSRF`; every one of them, and every form helper below, carries the token of the response's cookie |

```jinja
<p>{{ current_path }}</p>
{% if flash.notice %}<div class="alert">{{ flash.notice }}</div>{% endif %}
```

## Form helpers

### form_tag

Opens a form. It adds no CSRF token: put [`{{ csrf_field() }}`](#csrf_field) inside the form.

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

Non-standard methods (put, patch, delete) automatically add a hidden `_method` field. `multipart=true` sets
`enctype="multipart/form-data"`; there is no file-field helper, so write `<input type="file" name="file">` yourself.

The field helpers below name an input `object[attribute]` (`user[name]`) and give it the id `object_attribute`
(`user_name`; `object_attribute_value` for a radio button), unless you pass `id`.

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

The value is the template variable `csrf_token`, which `view` adds while a request is served once the app uses
`Azu::Handler::CSRF`. Without it the field's value is empty. `csrf_meta` reads the same variable.

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

Generates a checkbox, preceded by a hidden input with the value `0` so an unchecked box is still sent:

```jinja
{{ checkbox("user", "active", checked=true) }}
{{ checkbox("user", "newsletter", label="Subscribe to newsletter") }}
```

Additional parameters: `value` (default `"1"`), `checked`, `label`, `class`, `id`, `disabled`. It takes no `required`.

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

## URL helpers

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

A link with `target="_blank"` and no `rel` gets `rel="noopener noreferrer"`; no other link gets a `rel` you did not
pass.

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

### is_current_page

Filter that checks if a path matches the current page:

```jinja
{% if "/" | is_current_page %}
  <span class="active">Home</span>
{% endif %}
{% if "/users" | is_current_page(exact=false) %}...{% endif %}  {# true on /users/5 too #}
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `exact` | bool | `true` | Exact match vs prefix match |

The filter is also registered as `current_page?`, but Crinja cannot parse a name that ends in `?`
(`TemplateSyntaxError: Not implemented expression value`), so templates use `is_current_page`.

{% hint style="warning" %}
`is_current_page` and `active_class` compare with the [request variable](#request-variables) `current_path`.
Rendered without it, they compare with `/`, so the `/` link is active on every page.
{% endhint %}

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

Returns the request's `Referer` header, or `fallback` (default `/`) when there is none or when it is not a safe
URL (a scheme other than http, https, mailto or tel, such as `javascript:`):

```jinja
{{ link_to("Back", back_url(fallback="/posts")) }}
```

---

## Type-safe endpoint helpers

Azu automatically generates type-safe URL and form helpers from your endpoint definitions. The HTTP method is part of the helper name, making it impossible to confuse which action will be performed.

### How they're generated

When you define an endpoint with an HTTP method, Azu auto-generates helpers:

<details>

<summary>The five endpoints of this example</summary>

```crystal
struct PageResponse
  include Azu::Response

  def render
    ""
  end
end

struct UsersEndpoint
  include Azu::Endpoint(Azu::Request, PageResponse)
  get "/users"

  def call : PageResponse
    PageResponse.new
  end
end

struct UserEndpoint
  include Azu::Endpoint(Azu::Request, PageResponse)
  get "/users/:id"

  def call : PageResponse
    PageResponse.new
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(Azu::Request, PageResponse)
  post "/users"

  def call : PageResponse
    PageResponse.new
  end
end

struct UpdateUserEndpoint
  include Azu::Endpoint(Azu::Request, PageResponse)
  put "/users/:id"

  def call : PageResponse
    PageResponse.new
  end
end

struct DeleteUserEndpoint
  include Azu::Endpoint(Azu::Request, PageResponse)
  delete "/users/:id"

  def call : PageResponse
    PageResponse.new
  end
end
```

</details>

The resource part of a helper name is the endpoint's type name without `Endpoint`, underscored. For a namespaced
endpoint it is the last two segments joined: `Blog::Posts::ShowEndpoint` gives `posts_show`, so its link helper is
`link_to_get_posts_show`. The helpers are registered when the `get`, `post`, ... line runs, that is, when the type is defined.

This generates the following helpers:

| Endpoint | Generated Helpers |
|----------|-------------------|
| `UsersEndpoint.get "/users"` | `link_to_get_users()` |
| `UserEndpoint.get "/users/:id"` | `link_to_get_user(id=...)` |
| `CreateUserEndpoint.post "/users"` | `link_to_post_create_user()`, `form_for_post_create_user()` |
| `UpdateUserEndpoint.put "/users/:id"` | `link_to_put_update_user(id=...)`, `form_for_put_update_user(id=...)` |
| `DeleteUserEndpoint.delete "/users/:id"` | `link_to_delete_delete_user(id=...)`, `form_for_delete_delete_user(id=...)`, `button_to_delete_delete_user(id=...)` |

{% hint style="warning" %}
The helpers do not check their arguments: the helper of a route with `:id` called without `id` prints the pattern
itself (`href="/users/:id"`).
{% endhint %}

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

Generates form opening tags for non-GET endpoints. The form carries the request's CSRF token as a hidden `_csrf`
field (no field when the render has no [`csrf_token`](#request-variables)), so it needs no `csrf_field()`. PUT,
PATCH and DELETE forms also get a hidden `_method` field:

```jinja
{# POST form #}
{{ form_for_post_create_user(class="user-form") }}
  {{ text_field("user", "name") }}
  {{ submit_button("Create") }}
{{ end_form() }}
{# Output: <form action="/users" method="post" class="user-form"><input type="hidden" name="_csrf" value="..." />... #}

{# PUT form (auto-includes _method hidden field) #}
{{ form_for_put_update_user(id="123", class="edit-form") }}
  {{ text_field("user", "name", value=user.name) }}
  {{ submit_button("Update") }}
{{ end_form() }}
{# Output: <form action="/users/123" method="post" class="edit-form">
     <input type="hidden" name="_csrf" value="..." /><input type="hidden" name="_method" value="put">... #}

{# DELETE form #}
{{ form_for_delete_delete_user(id="123") }}
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
  {# generates: <input type="hidden" name="redirect_to" value="/dashboard">
               <input type="hidden" name="source" value="signup"> #}
  {{ text_field("user", "name") }}
  {{ submit_button("Create") }}
{{ end_form() }}
```

### button_to_delete_{resource}

Generates a complete delete form with a submit button (only for DELETE endpoints), with the CSRF field like
`form_for_*`:

```jinja
{{ button_to_delete_delete_user(id="123") }}
{# Output:
<form action="/users/123" method="post" style="display:inline">
  <input type="hidden" name="_csrf" value="..." />
  <input type="hidden" name="_method" value="delete">
  <button type="submit">Delete</button>
</form>
#}

{# With custom text and confirmation #}
{{ button_to_delete_delete_user(text="Remove User", id="123", confirm="Are you sure?") }}
{# Output:
<form action="/users/123" method="post" style="display:inline">
  <input type="hidden" name="_csrf" value="..." />
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

### {resource}_path

Every endpoint also registers a filter that prints its path. The filter ignores the value it is applied to and
fills `:id` from its `id` argument:

```jinja
{{ "" | user_path(id=5) }}          {# /users/5 #}
{{ "" | posts_show_path(id="hello") }} {# /posts/hello, for Blog::Posts::ShowEndpoint #}
```

Without `id` the `:id` segment is left empty (`/users/`). The filter survives `Azu::Helpers::Registry.reset!`.

In Crystal, `Endpoint.path(**params)` builds the same path, with the prefix of the app it is mounted in; each
argument replaces the path parameter of its name:

```crystal
struct UserPage
  include Azu::Response

  def render
    ""
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserPage)

  get "/users/:id"

  def call : UserPage
    UserPage.new
  end
end

ShowUserEndpoint.path(id: 5) # => "/users/5"
ShowUserEndpoint.path        # => "/users/:id"
```

### Helper naming convention

The helper name is derived from the endpoint class name:

| Class Name | Helper Resource Name |
|------------|---------------------|
| `UsersEndpoint` | `users` |
| `UserEndpoint` | `user` |
| `CreateUserEndpoint` | `create_user` |
| `Admin::UsersEndpoint` | `admin_users` |
| `Api::V1::UserEndpoint` | `v1_user` |

---

## Asset helpers

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

### preload_tag

Function that generates a `<link rel="preload">`:

```jinja
{{ preload_tag("fonts/inter.woff2", as="font", type="font/woff2") }}
{# <link rel="preload" href="/assets/fonts/inter.woff2" as="font" type="font/woff2" crossorigin="anonymous" /> #}
{{ preload_tag("app.css", as="style") }}
{# <link rel="preload" href="/assets/app.css" as="style" /> #}
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `href` | string | `""` | Asset path; an `http(s)://` or `/` URL is kept as it is, anything else gets the asset prefix |
| `as` | string | `""` | The `as` attribute (`font`, `style`, `script`, `image`, ...) |
| `type` | string | `nil` | MIME type |
| `crossorigin` | any | `nil` | Any true value gives `crossorigin="anonymous"` (a string such as `"use-credentials"` too); `as="font"` gets it without asking |

### inline_svg

Function that prints the content of an SVG file, so CSS can style it:

```jinja
{{ inline_svg("icons/check.svg", class="icon", title="Done") }}
{# <svg class="icon" viewBox="0 0 24 24"><title>Done</title><path d="M0 0"/></svg> #}
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `path` | string | `""` | File below `public/assets/` of the working directory; a path that starts with `/` is read as it is, from the file system |
| `class`, `id`, `width`, `height` | string | `nil` | Added to the `<svg>` tag |
| `title` | string | `nil` | A `<title>` inserted after the first tag, for screen readers |

The file is read on every render. A file that cannot be read prints
`<svg class="svg-placeholder"><text>SVG not found: icons/missing.svg</text></svg>`. The file's content is not
escaped: inline only SVG files you ship, never a path that comes from a request.

---

## Date helpers

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

### distance_of_time_between

Function that describes the time between two moments in the same words:

```jinja
{{ distance_of_time_between(from_time="2026-01-01", to_time="2026-03-01") }}  {# 1 month #}
{{ distance_of_time_between(from_time=1767225600, to_time=1767229200) }}    {# 1 hour #}
{{ distance_of_time_between(from_time=post.published_at) }}                  {# from then until now #}
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `from_time` | time, int or string | now | Start |
| `to_time` | time, int or string | now | End |

A `Time` is used as it is, an integer (or a string of digits) is a unix timestamp, and another string is read as a
`YYYY-MM-DD` date: a time of day after the date is ignored. A string that is not a date counts as now. The order
does not matter. Words go up to years: `seconds`, `minutes`, `hours`, `days`, `weeks`, `months` (30 days), `years`
(365 days).

---

## Number helpers

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
{{ 1234 | number_to_human }}                {# 1.2 thousand #}
{{ 1234567 | number_to_human }}             {# 1.2 million #}
{{ 1234567890 | number_to_human }}          {# 1.2 billion #}
{{ 1234 | number_to_human(precision=2) }}   {# 1.23 thousand #}
```

### ordinal

Filter that adds the English ordinal suffix:

```jinja
{{ 1 | ordinal }} {{ 2 | ordinal }} {{ 3 | ordinal }} {{ 11 | ordinal }} {{ 22 | ordinal }}  {# 1st 2nd 3rd 11th 22nd #}
```

A value that is not a number prints `0th`.

---

## HTML helpers

### safe_html

Filter that marks content as safe (no escaping):

```jinja
{{ html_content | safe_html }}
```

{% hint style="danger" %}
Only use with trusted content to prevent XSS.
{% endhint %}

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

The text and the matches are escaped (the phrase is searched in the raw text, so `{{ "a & b" | highlight("&") }}`
prints `a <mark>&amp;</mark> b`); only the `highlighter` markup, which you write, is passed through. Text that is
already safe (a `SafeString`, e.g. after `| e`) is used as it is.

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

### urlize

Filter that turns `http://`, `https://` and `www.` addresses into links, and escapes the rest of the text. It
replaces Crinja's own `urlize`, which escapes nothing and links any `scheme://`:

```jinja
{{ "Docs at https://example.com/docs and www.crystal-lang.org" | urlize }}
{# Docs at <a href="https://example.com/docs" rel="noopener">https://example.com/docs</a> and
   <a href="http://www.crystal-lang.org" rel="noopener">www.crystal-lang.org</a> #}
{{ "see https://example.com/a/very/long/path" | urlize(trim_url_limit=20, nofollow=true, target="_blank") }}
{# see <a href="https://example.com/a/very/long/path" rel="nofollow noopener" target="_blank">https://example.co...</a> #}
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `trim_url_limit` | int | `nil` | Shortens the text of a link of this length or longer to `trim_url_limit - 2` characters and `...` |
| `nofollow` | bool | `false` | Adds `nofollow` to `rel` |
| `target` | string | `nil` | The `target` attribute |
| `rel` | string | `nil` | More `rel` values; `noopener` is always added |

Text that is already safe (`| safe`) is not escaped again; its tags are copied as they are, and text inside an
existing `<a>` is not linked twice.

`urlize` reads markup with a simplified tokenizer, which differs from a browser in three known ways: a CDATA section
is treated as a section also in HTML content (a browser reads it as a bogus comment that ends at the first `>`), a
quote inside an attribute name, an end tag (`</a"`) or a bogus comment (`<?"`) starts a quoted value (a browser keeps it
in the name or the comment), and the script double-escape
state (`<!-- <script>`) is not modelled, so `</script>` always ends a script. A single comment, CDATA section or tag
larger than a few MB exceeds the regex engine's limit; the text is then returned as it is, without links (only text marked `safe` can reach this, as the filter escapes the rest first), and a warning without any of
the content is logged.

### cycle

Function that returns its values in turn, one per call:

```jinja
{{ cycle(values=["odd", "even"]) }} {{ cycle(values=["odd", "even"]) }} {{ cycle(values=["odd", "even"]) }}
{# odd even odd #}
```

{% hint style="warning" %}
Inside a `for` loop `cycle` returns the first value on every iteration: the position it keeps does not outlive one
pass of the loop body. Use Jinja's `loop.cycle("odd", "even")` there.
{% endhint %}

### content_tag

Function that generates an HTML tag:

```jinja
{{ content_tag(name="div", content="Hello", class="container") }}
{# <div class="container">Hello</div> #}
```

`content` is escaped unless it is already safe markup (another helper's output, or `| safe`).

### Attribute names and URLs

Tag names must match `[A-Za-z][A-Za-z0-9-]*` (anything else raises `ArgumentError`, so a user value can never become a
second tag). Attribute names, in every helper that takes `attrs`, `data` or similar hashes, must match
`[A-Za-z_:][-A-Za-z0-9_:.]*`; an attribute with another name is left out and logged at `warn`.

`link_to` (`href`), `button_to` (`action`) and `form_tag` (`action`) only point to `http`, `https`, `mailto`, `tel`, a
relative path, a query or a fragment (the scheme is compared case-insensitively, and tabs, newlines and control
characters inside it are ignored, as browsers do). Any other scheme (`javascript:`, `data:`, `vbscript:`, `file:`, ...)
is replaced: `link_to` prints `#`, `button_to` and `form_tag` print `about:invalid`. The value is escaped as well, so
`&#106;avascript:` stays text. Use `Azu::Helpers::Util.safe_url(url)` in your own helpers. Asset helpers
(`image_tag`, `javascript_tag`, `stylesheet_tag`, ...) only keep an `http(s)://` or `/` URL as it is and prefix the
asset path to anything else. To link to another scheme, write the `<a>` yourself.

---

## i18n helpers

Translations are YAML (or JSON) files under the load path (`locales/` by default, see the
[i18n options](../configuration/options.md#i18n)), with the locale as the top-level key:

{% code title="locales/en.yml" %}
```yaml
# locales/en.yml
en:
  welcome:
    title: "Welcome!"
    greeting: "Hello, %{name}!"
  date:
    short: "%b %d"
    long: "%B %d, %Y"
```
{% endcode %}

### t (translate)

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

{% code title="locales/en.yml" %}
```yaml
# locales/en.yml
en:
  users:
    count:
      zero: "No users"
      one: "1 user"
      other: "%{count} users"
```
{% endcode %}

```jinja
{{ t("users.count", count=0) }}  {# No users #}
{{ t("users.count", count=1) }}  {# 1 user #}
{{ t("users.count", count=5) }}  {# 5 users #}
```

### l (localize)

Filter that localizes dates using translation formats:

```jinja
{{ created_at | l("date.short") }}  {# Jan 15 #}
{{ created_at | l("date.long") }}   {# January 15, 2024 #}
```

`l("date.short")` reads the key `date.short` as written, so the formats sit directly under `date` in the locale
file. When the key is missing it falls back to built-in formats for `date.short` (`%b %d`), `date.long`
(`%B %d, %Y`), `time.short`, `time.long`, `datetime.short` and `datetime.long`.

### current_locale

Function that returns the current locale:

```jinja
{{ current_locale() }}  {# en #}
```

### Choosing the locale per request

`Azu::Handler::Locale` serves each request in the available locale that best matches its `Accept-Language` header, or in the default locale when none matches. The locale applies to everything the request does, including template rendering, and ends with the request. Nothing reads a `?locale=` parameter, so a link cannot switch the locale:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Locale.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

To choose the locale yourself, for example from a user setting, wrap the work in `with_locale`. The locale belongs to the current fiber, so concurrent requests never see each other's, and the previous locale is restored afterwards:

```crystal
user_locale = "es"

Azu::Helpers::I18n.with_locale(user_locale) do
  # render, send emails, ...
end
```

{% hint style="warning" %}
Assigning `Azu::Helpers::I18n.locale = "es"` directly also stays within the fiber, but a connection's fiber serves several requests in turn. Only assign it while handling a request that runs behind `Azu::Handler::Locale`, which discards it when the request ends.
{% endhint %}

### available_locales

Function that returns available locales:

```jinja
{% for locale in available_locales() %}
  <li lang="{{ locale }}">{{ locale | locale_name }}</li>
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

## Component helpers

Spark live views are not driven by template helpers: install the client with
`Azu::Spark.script_tag` and build reactive elements with the `spark_click` / `spark_change` /
`spark_submit` bindings inside `Azu::Spark::Component#render`. See
[Spark Live Views](../../explanation/spark-live-views.md).

### component_id

Returns the `id` of a component object (or its string form).

---

## Custom helpers

`Azu::Helpers` registers helpers of your own in the same registry. Each macro takes a name, or a named tuple of
default arguments and a name; the block runs on every call and returns the value to print:

```crystal
require "azu"

Azu::Helpers.function :current_year do
  Time.utc.year.to_s
end

Azu::Helpers.function({name: "World"}, :greet) do
  "Hello, #{arguments["name"]}!"
end

Azu::Helpers.filter({times: 1}, :shout) do
  target.to_s.upcase + "!" * arguments["times"].to_i
end

Azu::Helpers.test :blank do
  target.to_s.strip.empty?
end

Azu::Helpers.global :app_name, "My Application"
```

```jinja
{{ greet() }} {{ greet(name="Ada") }}      {# Hello, World! Hello, Ada! #}
{{ "hi" | shout }} {{ "hi" | shout(times=3) }}  {# HI! HI!!! #}
{% if title is blank %}Untitled{% endif %}
<title>{{ app_name }}</title>
```

| Macro | Template use | The block sees |
|---|---|---|
| `Azu::Helpers.function(name)` / `function(defaults, name)` | `{{ name(arg=value) }}` | `arguments`, `env` |
| `Azu::Helpers.filter(name)` / `filter(defaults, name)` | `{{ value \| name(arg=value) }}` | `target` (the value), `arguments`, `env` |
| `Azu::Helpers.test(name)` / `test(defaults, name)` | `{% if value is name %}` | `target`, `arguments`, `env` |
| `Azu::Helpers.global(name, value)` | `{{ name }}` | (a value, not a block) |

An argument is read by name with `arguments["name"]`, which is a `Crinja::Value`; arguments not named in the
defaults are ignored. A name registered twice keeps the last registration, but the built-in helpers are registered
again whenever a template set builds its loader (when `config.templates` is first used, on `path=` and on a hot
reload), so a helper of your own cannot take the name of a built-in one.

`Azu::Helpers::Registry` holds the registrations (`register_filter`, `register_function`, `register_test`,
`register_global`, and `filters`, `functions`, `tests`, `globals`, `has_filter?`, ... to read them). Templates apply
them on their next `load` whenever the registry has changed, so a helper registered after boot still reaches every
template. `Registry.reset!` (for specs) removes every registration except the endpoints' `{resource}_path` filters.

## Limits

- Helpers are process-wide: every app in the process, and every template, sees the same set.
- The date helpers (`time_ago`, `relative_time`, `distance_of_time_between`) read the system clock, not
  `Azu::Clock`.

## See also

- [Templates and Renderable](renderable.md)
- [Template engine](engine.md)
- [Render HTML templates](../../how-to/templates/render-html-templates.md)
- [i18n options](../configuration/options.md#i18n)
