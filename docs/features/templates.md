# Templates

Azu includes a powerful template engine based on Jinja2 that provides server-side rendering, hot reloading, and a markup DSL for building dynamic web applications.

## What are Templates?

Templates in Azu allow you to:

- **Generate HTML**: Create dynamic HTML pages
- **Variable Interpolation**: Insert data into templates
- **Control Structures**: Use loops, conditionals, and inheritance
- **Hot Reloading**: Automatic template reloading in development
- **Markup DSL**: Programmatic HTML generation

## Template Engine

Azu uses Crinja, a Jinja2-compatible template engine for Crystal:

### Basic Template

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>{{ title }}</title>
  </head>
  <body>
    <h1>{{ title }}</h1>
    <p>Welcome, {{ user.name }}!</p>
  </body>
</html>
```

### Template Variables

Pass data to templates:

```crystal
struct UserPage
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@user : User)
  end

  def render
    view "users/show.html", {
      "user" => @user,
      "title" => "User Profile",
      "timestamp" => Time.utc.to_rfc3339
    }
  end
end
```

## Template Syntax

### Variable Interpolation

```html
<!-- Basic variables -->
<h1>{{ title }}</h1>
<p>{{ user.name }}</p>
<p>{{ user.email }}</p>

<!-- Safe HTML (escaped by default) -->
<p>{{ user.bio }}</p>

<!-- Raw HTML (unescaped) -->
<div>{{ user.html_content | safe }}</div>

<!-- Default values -->
<p>{{ user.phone | default("Not provided") }}</p>
```

### Control Structures

#### Conditionals

```html
{% if user.is_admin %}
<div class="admin-panel">
  <h2>Admin Controls</h2>
  <a href="/admin">Admin Dashboard</a>
</div>
{% elif user.is_moderator %}
<div class="moderator-panel">
  <h2>Moderator Controls</h2>
  <a href="/moderate">Moderate Content</a>
</div>
{% else %}
<div class="user-panel">
  <h2>User Controls</h2>
  <a href="/profile">Edit Profile</a>
</div>
{% endif %}
```

#### Loops

```html
<!-- Simple loop -->
<ul>
  {% for user in users %}
  <li>{{ user.name }} - {{ user.email }}</li>
  {% endfor %}
</ul>

<!-- Loop with index -->
<ol>
  {% for user in users %}
  <li>{{ loop.index }}. {{ user.name }}</li>
  {% endfor %}
</ol>

<!-- Loop with conditions -->
<div class="user-list">
  {% for user in users %} {% if user.is_active %}
  <div class="user-card">
    <h3>{{ user.name }}</h3>
    <p>{{ user.email }}</p>
  </div>
  {% endif %} {% endfor %}
</div>
```

#### Loop Variables

```html
{% for user in users %}
<div class="user-item">
  <h3>{{ user.name }}</h3>
  <p>Position: {{ loop.index }} of {{ loop.length }}</p>

  {% if loop.first %}
  <span class="first-user">First User</span>
  {% endif %} {% if loop.last %}
  <span class="last-user">Last User</span>
  {% endif %} {% if loop.index is divisibleby 2 %}
  <span class="even-row">Even Row</span>
  {% endif %}
</div>
{% endfor %}
```

### Template Inheritance

#### Base Template

```html
<!-- base.html -->
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>{% block title %}My App{% endblock %}</title>
    <link rel="stylesheet" href="/css/style.css" />
  </head>
  <body>
    <header>
      <nav>
        <a href="/">Home</a>
        <a href="/about">About</a>
        <a href="/contact">Contact</a>
      </nav>
    </header>

    <main>{% block content %}{% endblock %}</main>

    <footer>
      <p>&copy; 2024 My App. All rights reserved.</p>
    </footer>
  </body>
</html>
```

#### Child Template

```html
<!-- users/index.html -->
{% extends "base.html" %} {% block title %}Users - My App{% endblock %} {% block
content %}
<h1>User List</h1>
<div class="user-list">
  {% for user in users %}
  <div class="user-card">
    <h3>{{ user.name }}</h3>
    <p>{{ user.email }}</p>
  </div>
  {% endfor %}
</div>
{% endblock %}
```

### Template Includes

```html
<!-- user_card.html -->
<div class="user-card">
  <h3>{{ user.name }}</h3>
  <p>{{ user.email }}</p>
  {% if user.avatar %}
  <img src="{{ user.avatar }}" alt="{{ user.name }}" />
  {% endif %}
</div>
```

```html
<!-- users/index.html -->
<h1>User List</h1>
<div class="user-list">
  {% for user in users %} {% include "user_card.html" %} {% endfor %}
</div>
```

## Markup DSL

Azu provides a programmatic markup DSL for generating HTML:

### Basic Markup

```crystal
class UserComponent
  include Azu::Component

  def content
    div class: "user-card" do
      h3 { text @user.name }
      p { text @user.email }

      if @user.avatar
        img src: @user.avatar, alt: @user.name
      end
    end
  end
end
```

### Nested Elements

```crystal
def content
  div class: "user-profile" do
    header do
      h1 { text "User Profile" }
      nav do
        a href: "/users", text: "Back to Users"
        a href: "/users/#{@user.id}/edit", text: "Edit User"
      end
    end

    main do
      section class: "user-info" do
        h2 { text @user.name }
        p { text @user.email }

        if @user.bio
          div class: "bio" do
            text @user.bio
          end
        end
      end
    end
  end
end
```

### Attributes

```crystal
def content
  div class: "container", id: "main-content", data: {user_id: @user.id} do
    h1 class: "title", style: "color: blue" do
      text "Welcome, #{@user.name}!"
    end

    form action: "/users/#{@user.id}", method: "post" do
      input type: "text", name: "name", value: @user.name
      input type: "email", name: "email", value: @user.email
      button type: "submit", class: "btn btn-primary" do
        text "Update User"
      end
    end
  end
end
```

### Loops and Conditionals

```crystal
def content
  div class: "user-list" do
    if @users.empty?
      p class: "empty-message" do
        text "No users found"
      end
    else
      @users.each do |user|
        div class: "user-item" do
          h3 { text user.name }
          p { text user.email }

          if user.is_admin
            span class: "admin-badge" do
              text "Admin"
            end
          end
        end
      end
    end
  end
end
```

## Template Configuration

Configure templates in your application:

```crystal
module MyApp
  include Azu

  configure do |config|
    # Template paths
    config.templates.path = ["templates", "views"]

    # Hot reloading in development
    config.template_hot_reload = config.env.development?

    # Template caching
    config.templates.cache = true
    config.templates.cache_size = 1000

    # Custom filters
    config.templates.filters = {
      "currency" => CurrencyFilter.new,
      "date" => DateFilter.new,
      "markdown" => MarkdownFilter.new
    }
  end
end
```

## Custom Filters

Create custom template filters:

```crystal
class CurrencyFilter
  def call(value : Float64, currency : String = "USD") : String
    case currency
    when "USD"
      "$%.2f" % value
    when "EUR"
      "€%.2f" % value
    when "GBP"
      "£%.2f" % value
    else
      "%.2f %s" % [value, currency]
    end
  end
end

class DateFilter
  def call(value : Time, format : String = "%Y-%m-%d") : String
    value.to_s(format)
  end
end

class MarkdownFilter
  def call(value : String) : String
    # Convert markdown to HTML
    Markdown.to_html(value)
  end
end
```

### Using Custom Filters

```html
<!-- Currency filter -->
<p>Price: {{ product.price | currency("USD") }}</p>
<p>Price: {{ product.price | currency("EUR") }}</p>

<!-- Date filter -->
<p>Created: {{ user.created_at | date("%B %d, %Y") }}</p>
<p>Updated: {{ user.updated_at | date("%Y-%m-%d %H:%M") }}</p>

<!-- Markdown filter -->
<div class="content">{{ user.bio | markdown }}</div>
```

## Template Helpers

Create helper methods for templates:

```crystal
class TemplateHelpers
  def self.user_avatar_url(user : User) : String
    if user.avatar
      user.avatar
    else
      "/images/default-avatar.png"
    end
  end

  def self.user_full_name(user : User) : String
    "#{user.first_name} #{user.last_name}".strip
  end

  def self.time_ago(time : Time) : String
    now = Time.utc
    diff = now - time

    if diff.total_seconds < 60
      "just now"
    elsif diff.total_seconds < 3600
      "#{diff.total_seconds.to_i / 60} minutes ago"
    elsif diff.total_seconds < 86400
      "#{diff.total_seconds.to_i / 3600} hours ago"
    else
      "#{diff.total_seconds.to_i / 86400} days ago"
    end
  end
end
```

### Using Helpers in Templates

```html
<!-- User avatar -->
<img src="{{ user | user_avatar_url }}" alt="{{ user | user_full_name }}" />

<!-- User full name -->
<h2>{{ user | user_full_name }}</h2>

<!-- Time ago -->
<p>Last seen: {{ user.last_seen | time_ago }}</p>
```

## Hot Reloading

Enable hot reloading in development:

```crystal
module MyApp
  include Azu

  configure do |config|
    # Enable hot reloading in development
    config.template_hot_reload = config.env.development?

    # Watch template directories
    config.templates.watch_dirs = ["templates", "views"]
  end
end
```

### Hot Reloading Features

- **Automatic Reloading**: Templates reload automatically when changed
- **File Watching**: Monitors template directories for changes
- **Development Only**: Only enabled in development environment
- **Performance**: Minimal overhead in production

## Template Caching

Cache templates for better performance:

```crystal
module MyApp
  include Azu

  configure do |config|
    # Enable template caching
    config.templates.cache = true
    config.templates.cache_size = 1000

    # Cache duration
    config.templates.cache_duration = 1.hour
  end
end
```

### Caching Strategies

- **Memory Caching**: Templates cached in memory
- **File Caching**: Compiled templates cached to disk
- **LRU Eviction**: Least recently used templates evicted
- **TTL Expiration**: Templates expire after specified time

## Template Testing

Test your templates:

```crystal
require "spec"

describe "User template" do
  it "renders user information correctly" do
    user = User.new("Alice", "alice@example.com")
    template = UserTemplate.new(user)

    html = template.render

    html.should contain("Alice")
    html.should contain("alice@example.com")
    html.should contain("<h1>User Profile</h1>")
  end

  it "handles missing user data" do
    user = User.new("Alice", "alice@example.com", bio: nil)
    template = UserTemplate.new(user)

    html = template.render

    html.should contain("Alice")
    html.should_not contain("Bio:")
  end
end
```

## Best Practices

### 1. Use Template Inheritance

```html
<!-- Good: Use inheritance -->
{% extends "base.html" %} {% block content %}
<h1>User List</h1>
<!-- content -->
{% endblock %}

<!-- Avoid: Duplicate HTML -->
<!DOCTYPE html>
<html>
  <head>
    <title>User List</title>
    <link rel="stylesheet" href="/css/style.css" />
  </head>
  <body>
    <h1>User List</h1>
    <!-- content -->
  </body>
</html>
```

### 2. Keep Templates Simple

```html
<!-- Good: Simple template -->
<h1>{{ title }}</h1>
<div class="user-list">
  {% for user in users %}
  <div class="user-card">
    <h3>{{ user.name }}</h3>
    <p>{{ user.email }}</p>
  </div>
  {% endfor %}
</div>

<!-- Avoid: Complex logic in templates -->
<h1>{{ title }}</h1>
<div class="user-list">
  {% for user in users %} {% if user.is_active %} {% if user.is_admin %}
  <div class="user-card admin">
    <h3>{{ user.name }} (Admin)</h3>
    <p>{{ user.email }}</p>
    <span class="admin-badge">Admin</span>
  </div>
  {% else %}
  <div class="user-card">
    <h3>{{ user.name }}</h3>
    <p>{{ user.email }}</p>
  </div>
  {% endif %} {% endif %} {% endfor %}
</div>
```

### 3. Use Includes for Reusable Components

```html
<!-- Good: Reusable component -->
{% include "user_card.html" %}

<!-- Avoid: Duplicate code -->
<div class="user-card">
  <h3>{{ user.name }}</h3>
  <p>{{ user.email }}</p>
</div>
```

### 4. Escape User Data

```html
<!-- Good: Automatic escaping -->
<p>{{ user.bio }}</p>

<!-- Avoid: Raw user data -->
<p>{{ user.bio | safe }}</p>
```

### 5. Use Meaningful Variable Names

```html
<!-- Good: Clear variable names -->
<h1>{{ page_title }}</h1>
<p>Welcome, {{ current_user.name }}!</p>

<!-- Avoid: Generic variable names -->
<h1>{{ title }}</h1>
<p>Welcome, {{ user.name }}!</p>
```

## Performance Considerations

### 1. Template Caching

```crystal
# Enable template caching
config.templates.cache = true
config.templates.cache_size = 1000
```

### 2. Minimize Template Complexity

```html
<!-- Good: Simple template -->
<h1>{{ title }}</h1>
<div class="content">{{ content }}</div>

<!-- Avoid: Complex template with many conditionals -->
<h1>{{ title }}</h1>
<div class="content">
  {% if user.is_admin %} {% if user.has_permission("edit") %} {% if
  content.is_published %}
  <!-- Complex nested logic -->
  {% endif %} {% endif %} {% endif %}
</div>
```

### 3. Use Includes Sparingly

```html
<!-- Good: Use includes for complex components -->
{% include "user_card.html" %}

<!-- Avoid: Overuse of includes -->
{% include "header.html" %} {% include "nav.html" %} {% include "sidebar.html"
%} {% include "content.html" %} {% include "footer.html" %}
```

## Next Steps

Now that you understand templates:

1. **[Components](components.md)** - Build interactive UI components
2. **[WebSockets](websockets.md)** - Add real-time features
3. **[Caching](caching.md)** - Implement template caching
4. **[Testing](../testing.md)** - Test your templates
5. **[Performance](../advanced/performance.md)** - Optimize template performance

---

_Templates in Azu provide a powerful way to generate dynamic HTML content. With Jinja2-compatible syntax, hot reloading, and a markup DSL, they make building web applications efficient and maintainable._
