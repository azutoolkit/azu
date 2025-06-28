# Template Engine

Azu's template engine is built on top of **Crinja**, a Jinja2-compatible templating engine for Crystal. It provides powerful server-side rendering capabilities with type-safe data binding and automatic escaping.

## Overview

The template engine provides:

- **Jinja2-compatible syntax** for familiar templating
- **Type-safe data binding** with compile-time validation
- **Automatic escaping** for security
- **Template inheritance** and includes
- **Custom filters and functions** for data transformation

## Basic Usage

### Template Rendering

```crystal
struct UserProfileResponse
  include Response
  include Templates::Renderable

  def initialize(@user : User)
  end

  def render
    view "user_profile.html", {
      user: @user,
      is_admin: @user.admin?,
      posts: @user.recent_posts
    }
  end
end
```

### Template File (`user_profile.html`)

```html
{% extends "base.html" %} {% block title %}{{ user.name }}'s Profile{% endblock
%} {% block content %}
<div class="user-profile">
  <h1>{{ user.name }}</h1>
  <p class="email">{{ user.email }}</p>

  {% if is_admin %}
  <div class="admin-badge">Administrator</div>
  {% endif %}

  <div class="user-stats">
    <span>Posts: {{ posts.size }}</span>
    <span>Joined: {{ user.created_at | date("%B %Y") }}</span>
  </div>

  {% if posts.any? %}
  <div class="recent-posts">
    <h2>Recent Posts</h2>
    {% for post in posts %}
    <article class="post">
      <h3>{{ post.title }}</h3>
      <p>{{ post.excerpt }}</p>
      <time>{{ post.created_at | date("%Y-%m-%d") }}</time>
    </article>
    {% endfor %}
  </div>
  {% else %}
  <p>No posts yet.</p>
  {% endif %}
</div>
{% endblock %}
```

## Template Syntax

### Variables

Variables are accessed using double curly braces:

```html
<h1>{{ user.name }}</h1>
<p>Email: {{ user.email }}</p>
<p>Age: {{ user.age | default("Not specified") }}</p>
```

### Control Structures

#### If Statements

```html
{% if user.admin? %}
<div class="admin-panel">
  <h2>Admin Controls</h2>
  <!-- Admin content -->
</div>
{% elif user.moderator? %}
<div class="moderator-panel">
  <h2>Moderator Controls</h2>
  <!-- Moderator content -->
</div>
{% else %}
<p>Regular user account.</p>
{% endif %}
```

#### For Loops

```html
<ul class="user-list">
  {% for user in users %}
  <li class="user-item">
    <span class="name">{{ user.name }}</span>
    <span class="email">{{ user.email }}</span>
    {% if user.active? %}
    <span class="status active">Active</span>
    {% else %}
    <span class="status inactive">Inactive</span>
    {% endif %}
  </li>
  {% else %}
  <li class="no-users">No users found.</li>
  {% endfor %}
</ul>
```

#### While Loops

```html
{% set counter = 0 %} {% while counter < 5 %}
<div class="item-{{ counter }}">Item {{ counter + 1 }}</div>
{% set counter = counter + 1 %} {% endwhile %}
```

### Template Inheritance

#### Base Template (`base.html`)

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>{% block title %}Azu Application{% endblock %}</title>
    <link rel="stylesheet" href="/css/app.css" />
  </head>
  <body>
    <header>
      <nav>
        <a href="/">Home</a>
        <a href="/users">Users</a>
        <a href="/posts">Posts</a>
      </nav>
    </header>

    <main>
      {% block content %}
      <!-- Default content -->
      {% endblock %}
    </main>

    <footer>
      <p>&copy; 2024 Azu Application</p>
    </footer>

    <script src="/js/app.js"></script>
  </body>
</html>
```

#### Child Template

```html
{% extends "base.html" %} {% block title %}User Profile - {{ user.name }}{%
endblock %} {% block content %}
<div class="user-profile">
  <h1>{{ user.name }}</h1>
  <!-- User profile content -->
</div>
{% endblock %}
```

### Template Includes

#### Include Template (`user_card.html`)

```html
<div class="user-card">
  <img src="{{ user.avatar_url }}" alt="{{ user.name }}" class="avatar" />
  <div class="user-info">
    <h3>{{ user.name }}</h3>
    <p>{{ user.email }}</p>
    <span class="role">{{ user.role }}</span>
  </div>
</div>
```

#### Using Include

```html
<div class="user-list">
  {% for user in users %} {% include "user_card.html" %} {% endfor %}
</div>
```

## Filters

### Built-in Filters

#### String Filters

```html
<!-- Uppercase -->
<h1>{{ user.name | upper }}</h1>

<!-- Lowercase -->
<p>{{ user.email | lower }}</p>

<!-- Capitalize -->
<p>{{ user.title | capitalize }}</p>

<!-- Truncate -->
<p>{{ user.bio | truncate(100) }}</p>

<!-- Replace -->
<p>{{ user.description | replace("old", "new") }}</p>
```

#### Number Filters

```html
<!-- Format number -->
<p>Posts: {{ user.post_count | number }}</p>

<!-- Round -->
<p>Rating: {{ user.rating | round(2) }}</p>

<!-- Default value -->
<p>Age: {{ user.age | default("Unknown") }}</p>
```

#### Date Filters

```html
<!-- Format date -->
<p>Joined: {{ user.created_at | date("%B %d, %Y") }}</p>

<!-- Relative time -->
<p>Last seen: {{ user.last_seen | timeago }}</p>

<!-- Custom format -->
<p>Updated: {{ user.updated_at | date("%Y-%m-%d %H:%M") }}</p>
```

#### Array Filters

```html
<!-- Length -->
<p>Posts: {{ posts | length }}</p>

<!-- First/Last -->
<p>First post: {{ posts | first }}</p>
<p>Latest post: {{ posts | last }}</p>

<!-- Sort -->
{% for post in posts | sort(attribute="created_at") %}
<div>{{ post.title }}</div>
{% endfor %}

<!-- Filter -->
{% for post in posts | filter(attribute="published", value=true) %}
<div>{{ post.title }}</div>
{% endfor %}
```

### Custom Filters

#### Registering Custom Filters

```crystal
# Register custom filters
Azu::Templates.register_filter("currency") do |value, args|
  amount = value.as(Number)
  currency = args.first? || "USD"

  case currency
  when "USD"
    "$#{amount}"
  when "EUR"
    "€#{amount}"
  else
    "#{amount} #{currency}"
  end
end

Azu::Templates.register_filter("pluralize") do |value, args|
  count = value.as(Number)
  singular = args[0]
  plural = args[1]? || "#{singular}s"

  count == 1 ? singular : plural
end
```

#### Using Custom Filters

```html
<p>Price: {{ product.price | currency("USD") }}</p>
<p>{{ post_count | pluralize("post", "posts") }}</p>
```

## Functions

### Built-in Functions

```html
<!-- Range -->
{% for i in range(1, 10) %}
  <span>{{ i }}</span>
{% endfor %}

<!-- Random -->
<p>Random number: {{ random(1, 100) }}</p>

<!-- Now -->
<p>Current time: {{ now() | date("%Y-%m-%d %H:%M:%S") }}</p>

<!-- URL -->
<a href="{{ url("user_profile", id=user.id) }}">View Profile</a>
```

### Custom Functions

#### Registering Custom Functions

```crystal
# Register custom functions
Azu::Templates.register_function("gravatar_url") do |args|
  email = args[0].as(String)
  size = args[1]? || 80

  hash = Digest::MD5.hexdigest(email.downcase)
  "https://www.gravatar.com/avatar/#{hash}?s=#{size}&d=identicon"
end

Azu::Templates.register_function("format_file_size") do |args|
  bytes = args[0].as(Number)

  case
  when bytes < 1024
    "#{bytes} B"
  when bytes < 1024 * 1024
    "#{(bytes / 1024).round(1)} KB"
  when bytes < 1024 * 1024 * 1024
    "#{(bytes / (1024 * 1024)).round(1)} MB"
  else
    "#{(bytes / (1024 * 1024 * 1024)).round(1)} GB"
  end
end
```

#### Using Custom Functions

```html
<img src="{{ gravatar_url(user.email, 120) }}" alt="{{ user.name }}" />
<p>File size: {{ format_file_size(file.size) }}</p>
```

## Configuration

### Template Configuration

```crystal
# Configure template engine
Azu::Configuration.configure do |config|
  # Template directory
  config.template_path = "templates"

  # Enable template caching in production
  config.template_cache = production?

  # Custom template extensions
  config.template_extensions = [".html", ".jinja", ".template"]

  # Auto-reload templates in development
  config.template_auto_reload = development?

  # Template encoding
  config.template_encoding = "UTF-8"
end
```

### Environment-Specific Configuration

```crystal
# Development environment
Azu::Environment.configure :development do |config|
  config.template_cache = false
  config.template_auto_reload = true
  config.template_debug = true
end

# Production environment
Azu::Environment.configure :production do |config|
  config.template_cache = true
  config.template_auto_reload = false
  config.template_debug = false
end
```

## Security

### Automatic Escaping

The template engine automatically escapes output to prevent XSS attacks:

```html
<!-- User input is automatically escaped -->
<p>{{ user_input }}</p>

<!-- Raw output (use with caution) -->
<p>{{ user_input | safe }}</p>
```

### CSRF Protection

```html
<!-- Include CSRF token in forms -->
<form method="POST" action="/users">
  <input type="hidden" name="_csrf" value="{{ csrf_token() }}" />
  <input type="text" name="name" value="{{ user.name }}" />
  <button type="submit">Update</button>
</form>
```

## Performance

### Template Caching

```crystal
# Enable template caching
Azu::Configuration.configure do |config|
  config.template_cache = true
  config.template_cache_size = 1000
end
```

### Fragment Caching

```crystal
class UserListComponent < Azu::Component
  def content
    div class: "user-list" do
      users.each do |user|
        # Cache individual user fragments
        cached_fragment "user:#{user.id}", ttl: 300 do
          render_user_card(user)
        end
      end
    end
  end
end
```

### Template Precompilation

```crystal
# Precompile templates in production
if production?
  Azu::Templates.precompile_all!
end
```

## Error Handling

### Template Error Handling

```crystal
struct ErrorResponse
  include Response
  include Templates::Renderable

  def initialize(@error : Exception)
  end

  def render
    begin
      view "error.html", {
        error: @error,
        message: @error.message,
        backtrace: development? ? @error.backtrace : nil
      }
    rescue ex
      # Fallback to simple error response
      {
        error: "Template rendering failed",
        message: ex.message
      }.to_json
    end
  end
end
```

### Template Debugging

```crystal
# Enable template debugging
Azu::Configuration.configure do |config|
  config.template_debug = development?
  config.template_debug_info = true
end
```

## Best Practices

### 1. **Template Organization**

- Use logical directory structure
- Keep templates focused and single-purpose
- Use template inheritance for consistent layouts
- Organize includes and macros in separate files

### 2. **Performance**

- Cache frequently used templates
- Use fragment caching for expensive parts
- Minimize database queries in templates
- Precompile templates in production

### 3. **Security**

- Never trust user input
- Use automatic escaping
- Validate all template data
- Use CSRF protection for forms

### 4. **Maintainability**

- Use descriptive variable names
- Keep templates simple and readable
- Document complex template logic
- Use consistent naming conventions

## Next Steps

- [Markup DSL](markup.md) - Build components with Crystal code
- [Hot Reloading](hot-reload.md) - Development workflow
- [Template Examples](../playground/templates/) - Working examples

---

**Ready to build templates?** Start with the basic syntax examples above, then explore the [Markup DSL](markup.md) for component-based development.
