# How to Use Template Helpers

This guide shows how to use Azu's built-in template helpers for common web development tasks.

## Prerequisites

Template helpers are automatically available in all templates when using Azu's `Renderable` module.

## Building Forms

### Basic Form

```jinja
{{ form_tag("/users", method="post") }}
  {{ csrf_field() }}
  
  {{ label_tag("user_name", "Name") }}
  {{ text_field("user", "name", required=true) }}
  
  {{ label_tag("user_email", "Email") }}
  {{ email_field("user", "email", required=true) }}
  
  {{ submit_button("Create User") }}
{{ end_form() }}
```

This generates proper `name` attributes like `user[name]` and `user[email]`, which work with Azu's params parsing.

### Form with File Upload

```jinja
{{ form_tag("/upload", method="post", multipart=true) }}
  {{ csrf_field() }}
  
  {{ label_tag("file", "Choose file") }}
  <input type="file" name="file" id="file" accept="image/*">
  
  {{ submit_button("Upload") }}
{{ end_form() }}
```

### Form with Validation Styles

```jinja
{{ form_tag("/users", method="post") }}
  {{ csrf_field() }}
  
  <div class="form-group {% if errors['name'] %}has-error{% endif %}">
    {{ label_tag("user_name", "Name") }}
    {{ text_field("user", "name", value=form_data['name'], class="form-control") }}
    {% if errors['name'] %}
      <span class="error-message">{{ errors['name'] }}</span>
    {% endif %}
  </div>
  
  {{ submit_button("Submit") }}
{{ end_form() }}
```

### Select Dropdown

```jinja
{{ select_field("user", "role", options=[
  {"value": "user", "label": "Regular User"},
  {"value": "admin", "label": "Administrator"},
  {"value": "moderator", "label": "Moderator"}
], selected=user.role, include_blank="Select a role...") }}
```

### Checkbox and Radio Buttons

```jinja
{# Checkbox #}
{{ checkbox("user", "newsletter", label="Subscribe to newsletter") }}
{{ checkbox("user", "terms", required=true) }}
<label for="user_terms">I agree to the terms</label>

{# Radio buttons #}
{% for role in ["user", "admin", "moderator"] %}
  {{ radio_button("user", "role", value=role, checked=(user.role == role)) }}
  <label>{{ role | capitalize }}</label>
{% endfor %}
```

## Navigation with Active States

### Basic Navigation

```jinja
<nav>
  {{ link_to("Home", "/", class="nav-link " ~ ("/" | active_class("active"))) }}
  {{ link_to("About", "/about", class="nav-link " ~ ("/about" | active_class("active"))) }}
  {{ link_to("Contact", "/contact", class="nav-link " ~ ("/contact" | active_class("active"))) }}
</nav>
```

### With Conditional Active Class

```jinja
<nav>
  {% for item in [
    {"label": "Home", "path": "/"},
    {"label": "Blog", "path": "/blog"},
    {"label": "About", "path": "/about"}
  ] %}
    <a href="{{ item.path }}" 
       class="nav-link {% if item.path | is_current_page %}active{% endif %}">
      {{ item.label }}
    </a>
  {% endfor %}
</nav>
```

### External Links

```jinja
{# External links automatically get rel="noopener noreferrer" #}
{{ link_to("Documentation", "https://docs.example.com", target="_blank") }}
```

## Delete Buttons with Confirmation

```jinja
{# Simple delete #}
{{ button_to("Delete", "/posts/" ~ post.id, method="delete") }}

{# With confirmation #}
{{ button_to("Delete", "/posts/" ~ post.id, 
   method="delete", 
   confirm="Are you sure you want to delete this post?",
   class="btn btn-danger") }}
```

## Working with Assets

### Page Head Section

```jinja
<head>
  <meta charset="UTF-8">
  <title>{% block title %}My App{% endblock %}</title>
  
  {{ favicon_tag("favicon.ico") }}
  {{ stylesheet_tag("app.css") }}
  
  {# Preload critical fonts #}
  <link rel="preload" href="{{ 'fonts/inter.woff2' | asset_path }}" 
        as="font" type="font/woff2" crossorigin>
  
  {{ csrf_meta() }}
</head>
```

### Scripts at End of Body

```jinja
<body>
  {# ... content ... #}
  
  {{ javascript_tag("vendor.js") }}
  {{ javascript_tag("app.js", defer=true) }}
</body>
```

### Responsive Images

```jinja
{{ image_tag("hero.jpg", 
   alt="Welcome", 
   class="hero-image", 
   loading="lazy",
   width=1200,
   height=600) }}
```

## Internationalization

### Setup Locale Files

Create YAML files in your locales directory:

```yaml
# locales/en.yml
en:
  app_name: "My App"
  welcome:
    title: "Welcome!"
    greeting: "Hello, %{name}!"
  users:
    count:
      zero: "No users yet"
      one: "1 user"
      other: "%{count} users"
  date:
    formats:
      short: "%b %d"
      long: "%B %d, %Y"
```

### Using Translations

```jinja
<h1>{{ t("welcome.title") }}</h1>
<p>{{ t("welcome.greeting", name=user.name) }}</p>
<span>{{ t("users.count", count=users.size) }}</span>
```

### Formatting Dates

```jinja
<p>Created: {{ post.created_at | l("date.short") }}</p>
<p>Published: {{ post.published_at | l("date.long") }}</p>
```

### Language Switcher

```jinja
<div class="language-switcher">
  {% for locale in available_locales() %}
    <a href="?locale={{ locale }}" 
       class="{% if locale == current_locale() %}active{% endif %}">
      {{ locale | locale_name }}
    </a>
  {% endfor %}
</div>
```

## Formatting Numbers and Dates

### Currency and Numbers

```jinja
<span class="price">{{ product.price | currency("$") }}</span>
<span class="views">{{ article.views | number_with_delimiter }} views</span>
<span class="rating">{{ product.rating | percentage }} positive</span>
<span class="size">{{ file.size | filesize }}</span>
```

### Relative Times

```jinja
<small>{{ post.created_at | time_ago }}</small>
{# Output: "5 minutes ago", "2 days ago", etc. #}

<small>{{ event.starts_at | relative_time }}</small>
{# Output: "in 3 hours", "in 2 days", etc. #}
```

### Custom Date Formats

```jinja
<time datetime="{{ post.created_at | date_format('%Y-%m-%dT%H:%M:%SZ') }}">
  {{ post.created_at | date_format("%B %d, %Y at %I:%M %p") }}
</time>
```

## Safe HTML Output

### Escaping HTML (Default)

By default, all output is HTML-escaped:

```jinja
{{ user_input }}
{# "<script>" becomes "&lt;script&gt;" #}
```

### Marking Content as Safe

Only use with trusted content:

```jinja
{{ rendered_markdown | safe_html }}
```

### Auto-linking URLs

```jinja
{{ user_comment | auto_link }}
{# URLs and emails become clickable links #}
```

### Highlighting Search Terms

```jinja
{{ article.content | highlight(search_query) }}
{# Matching text wrapped in <mark> tags #}
```

## Complete Page Example

```jinja
{% extends "layouts/application.jinja" %}

{% block title %}{{ t("posts.show.title", title=post.title) }}{% endblock %}

{% block content %}
<article class="post">
  <header>
    <h1>{{ post.title }}</h1>
    <p class="meta">
      By {{ link_to(post.author.name, "/users/" ~ post.author.id) }}
      <time>{{ post.created_at | time_ago }}</time>
    </p>
  </header>
  
  <div class="content">
    {{ post.content | safe_html }}
  </div>
  
  <footer>
    {% if current_user and current_user.id == post.author.id %}
      {{ link_to(t("actions.edit"), "/posts/" ~ post.id ~ "/edit", class="btn") }}
      {{ button_to(t("actions.delete"), "/posts/" ~ post.id, 
         method="delete", 
         confirm=t("posts.confirm_delete"),
         class="btn btn-danger") }}
    {% endif %}
    
    {{ link_to(t("actions.back"), back_url(fallback="/posts"), class="btn btn-secondary") }}
  </footer>
</article>
{% endblock %}
```

## See Also

- [Template Helpers Reference](../../reference/templates/helpers.md)
- [Template Engine Reference](../../reference/templates/engine.md)
- [How to Render HTML Templates](render-html-templates.md)
