# Markup DSL

Azu's Markup DSL allows you to build HTML components directly in Crystal code with type safety, component composition, and real-time event handling. It provides a clean, readable syntax for generating HTML without template files.

## Overview

The Markup DSL provides:

- **Type-safe HTML generation** with compile-time validation
- **Component composition** for reusable UI elements
- **Real-time event handling** for interactive components
- **Clean, readable syntax** that mirrors HTML structure
- **Performance optimization** with minimal allocations

## Basic Usage

### Simple HTML Generation

```crystal
class WelcomeComponent < Azu::Component
  def content
    div class: "welcome" do
      h1 "Welcome to Azu!"
      p "Build fast, type-safe web applications with Crystal."

      button class: "btn btn-primary", onclick: "showFeatures()" do
        text "Learn More"
      end
    end
  end
end
```

### Component with Data

```crystal
class UserCardComponent < Azu::Component
  def initialize(@user : User)
  end

  def content
    div class: "user-card", id: "user-#{@user.id}" do
      img src: @user.avatar_url, alt: @user.name, class: "avatar"

      div class: "user-info" do
        h3 @user.name
        p @user.email
        span class: "role #{@user.role}" do
          text @user.role.capitalize
        end
      end

      div class: "actions" do
        button class: "btn btn-sm", onclick: "editUser(#{@user.id})" do
          text "Edit"
        end
        button class: "btn btn-sm btn-danger", onclick: "deleteUser(#{@user.id})" do
          text "Delete"
        end
      end
    end
  end
end
```

## HTML Elements

### Basic Elements

```crystal
def content
  # Headings
  h1 "Main Title"
  h2 "Subtitle"
  h3 "Section Title"

  # Paragraphs
  p "This is a paragraph."
  p class: "highlight" do
    text "This is a highlighted paragraph."
  end

  # Links
  a href: "/users", class: "nav-link" do
    text "View Users"
  end

  # Images
  img src: "/images/logo.png", alt: "Logo", class: "logo"

  # Lists
  ul class: "menu" do
    li "Home"
    li "About"
    li "Contact"
  end

  # Tables
  table class: "data-table" do
    thead do
      tr do
        th "Name"
        th "Email"
        th "Role"
      end
    end
    tbody do
      users.each do |user|
        tr do
          td user.name
          td user.email
          td user.role
        end
      end
    end
  end
end
```

### Forms

```crystal
def content
  form method: "POST", action: "/users", class: "user-form" do
    div class: "form-group" do
      label "Name", for: "name"
      input type: "text", id: "name", name: "name", value: @user.name, required: true
    end

    div class: "form-group" do
      label "Email", for: "email"
      input type: "email", id: "email", name: "email", value: @user.email, required: true
    end

    div class: "form-group" do
      label "Role", for: "role"
      select id: "role", name: "role" do
        option value: "user", selected: @user.role == "user" do
          text "User"
        end
        option value: "admin", selected: @user.role == "admin" do
          text "Administrator"
        end
      end
    end

    div class: "form-actions" do
      button type: "submit", class: "btn btn-primary" do
        text "Save User"
      end
      a href: "/users", class: "btn btn-secondary" do
        text "Cancel"
      end
    end
  end
end
```

## Component Composition

### Reusable Components

```crystal
class ButtonComponent < Azu::Component
  def initialize(@text : String, @variant : String = "primary", @size : String = "md")
  end

  def content
    button class: "btn btn-#{@variant} btn-#{@size}" do
      text @text
    end
  end
end

class ModalComponent < Azu::Component
  def initialize(@title : String, @id : String)
  end

  def content
    div class: "modal", id: @id do
      div class: "modal-dialog" do
        div class: "modal-content" do
          div class: "modal-header" do
            h5 class: "modal-title" do
              text @title
            end
            button type: "button", class: "btn-close", onclick: "closeModal('#{@id}')"
          end
          div class: "modal-body" do
            yield
          end
        end
      end
    end
  end
end
```

### Using Components

```crystal
class UserListComponent < Azu::Component
  def content
    div class: "user-list" do
      users.each do |user|
        UserCardComponent.new(user).render
      end

      div class: "actions" do
        ButtonComponent.new("Add User", "success").render
        ButtonComponent.new("Export", "secondary").render
      end
    end
  end
end
```

## Real-time Components

### Live Components with Events

```crystal
class CounterComponent < Azu::Component
  def initialize(@initial_count : Int32 = 0)
    @count = @initial_count
  end

  def content
    div class: "counter" do
      h3 "Counter"
      span id: "count", class: "count" do
        text @count.to_s
      end

      div class: "controls" do
        button class: "btn btn-sm", onclick: "increment()" do
          text "Increment"
        end
        button class: "btn btn-sm", onclick: "decrement()" do
          text "Decrement"
        end
        button class: "btn btn-sm btn-secondary", onclick: "reset()" do
          text "Reset"
        end
      end
    end
  end

  def on_event("increment", data)
    @count += 1
    update_element "count", @count.to_s
  end

  def on_event("decrement", data)
    @count -= 1
    update_element "count", @count.to_s
  end

  def on_event("reset", data)
    @count = @initial_count
    update_element "count", @count.to_s
  end
end
```

### Form Components with Validation

```crystal
class UserFormComponent < Azu::Component
  def initialize(@user : User? = nil)
    @errors = {} of String => String
  end

  def content
    form method: "POST", action: "/users", class: "user-form" do
      div class: "form-group" do
        label "Name", for: "name"
        input type: "text", id: "name", name: "name", value: @user.try(&.name), required: true
        if error = @errors["name"]?
          span class: "error" do
            text error
          end
        end
      end

      div class: "form-group" do
        label "Email", for: "email"
        input type: "email", id: "email", name: "email", value: @user.try(&.email), required: true
        if error = @errors["email"]?
          span class: "error" do
            text error
          end
        end
      end

      div class: "form-actions" do
        button type: "submit", class: "btn btn-primary" do
          text @user ? "Update User" : "Create User"
        end
      end
    end
  end

  def on_event("validation_error", data)
    @errors = data["errors"].as(Hash(String, String))
    render_errors
  end

  private def render_errors
    @errors.each do |field, message|
      update_element "#{field}-error", message
    end
  end
end
```

## Conditional Rendering

### If Statements

```crystal
def content
  div class: "user-profile" do
    h1 @user.name

    if @user.admin?
      div class: "admin-badge" do
        text "Administrator"
      end
    end

    if @user.avatar_url
      img src: @user.avatar_url, alt: @user.name, class: "avatar"
    else
      div class: "avatar-placeholder" do
        text @user.name[0].upcase
      end
    end

    unless @user.posts.empty?
      div class: "recent-posts" do
        h3 "Recent Posts"
        @user.posts.each do |post|
          div class: "post" do
            h4 post.title
            p post.excerpt
          end
        end
      end
    end
  end
end
```

### Case Statements

```crystal
def content
  div class: "status-indicator" do
    case @user.status
    when "active"
      span class: "status active" do
        text "Active"
      end
    when "inactive"
      span class: "status inactive" do
        text "Inactive"
      end
    when "suspended"
      span class: "status suspended" do
        text "Suspended"
      end
    else
      span class: "status unknown" do
        text "Unknown"
      end
    end
  end
end
```

## Loops and Iteration

### Basic Loops

```crystal
def content
  div class: "user-list" do
    users.each do |user|
      div class: "user-item" do
        h3 user.name
        p user.email
      end
    end
  end
end
```

### Loops with Index

```crystal
def content
  table class: "data-table" do
    thead do
      tr do
        th "#"
        th "Name"
        th "Email"
        th "Actions"
      end
    end
    tbody do
      users.each_with_index do |user, index|
        tr class: index.even? ? "even" : "odd" do
          td (index + 1).to_s
          td user.name
          td user.email
          td do
            button class: "btn btn-sm", onclick: "editUser(#{user.id})" do
              text "Edit"
            end
          end
        end
      end
    end
  end
end
```

### Conditional Loops

```crystal
def content
  div class: "posts" do
    if posts.any?
      posts.each do |post|
        article class: "post" do
          h2 post.title
          p post.excerpt
          time post.created_at.to_s("%Y-%m-%d")
        end
      end
    else
      div class: "no-posts" do
        text "No posts found."
      end
    end
  end
end
```

## Attributes and Properties

### Dynamic Attributes

```crystal
def content
  # Basic attributes
  div class: "container", id: "main-content" do
    text "Content"
  end

  # Conditional attributes
  div class: "alert #{@alert_type}", role: "alert" do
    text @message
  end

  # Data attributes
  div data_user_id: @user.id, data_role: @user.role do
    text @user.name
  end

  # Style attributes
  div style: "background-color: #{@bg_color}; color: #{@text_color}" do
    text "Styled content"
  end
end
```

### Boolean Attributes

```crystal
def content
  # Checkbox with checked state
  input type: "checkbox", checked: @user.active?, name: "active"

  # Disabled button
  button disabled: @user.locked?, class: "btn" do
    text "Edit"
  end

  # Required field
  input type: "email", required: true, name: "email"

  # Readonly field
  input type: "text", readonly: true, value: @user.id
end
```

## Event Handling

### Client-side Events

```crystal
def content
  div class: "interactive-component" do
    button onclick: "handleClick()", class: "btn" do
      text "Click Me"
    end

    input type: "text", onchange: "handleChange(this.value)", placeholder: "Type something"

    select onchange: "handleSelect(this.value)" do
      option value: "option1" do
        text "Option 1"
      end
      option value: "option2" do
        text "Option 2"
      end
    end
  end
end
```

### Server-side Event Handling

```crystal
class ChatComponent < Azu::Component
  def content
    div class: "chat" do
      div id: "messages", class: "messages" do
        @messages.each do |message|
          div class: "message" do
            span class: "user" do
              text message.user
            end
            span class: "text" do
              text message.text
            end
          end
        end
      end

      form onsubmit: "sendMessage(event)" do
        input type: "text", id: "message-input", placeholder: "Type a message..."
        button type: "submit" do
          text "Send"
        end
      end
    end
  end

  def on_event("send_message", data)
    message_text = data["text"].as(String)
    user = data["user"].as(String)

    # Add message to chat
    @messages << Message.new(user, message_text)

    # Update the messages container
    update_element "messages" do
      @messages.each do |message|
        div class: "message" do
          span class: "user" do
            text message.user
          end
          span class: "text" do
            text message.text
          end
        end
      end
    end
  end
end
```

## Performance Optimization

### Lazy Loading

```crystal
class LazyListComponent < Azu::Component
  def initialize(@items : Array(Item), @page_size : Int32 = 20)
    @current_page = 0
  end

  def content
    div class: "lazy-list" do
      div id: "items-container" do
        render_items(@current_page)
      end

      if @items.size > (@current_page + 1) * @page_size
        button onclick: "loadMore()", class: "btn btn-secondary" do
          text "Load More"
        end
      end
    end
  end

  def on_event("load_more", data)
    @current_page += 1
    new_items = render_items(@current_page)

    append_element "items-container", new_items
  end

  private def render_items(page : Int32)
    start_index = page * @page_size
    end_index = Math.min(start_index + @page_size, @items.size)

    @items[start_index...end_index].map do |item|
      div class: "item" do
        text item.name
      end
    end
  end
end
```

### Caching

```crystal
class CachedComponent < Azu::Component
  def content
    cached_fragment "user-list", ttl: 300 do
      div class: "user-list" do
        users.each do |user|
          UserCardComponent.new(user).render
        end
      end
    end
  end
end
```

## Best Practices

### 1. **Component Structure**

- Keep components focused and single-purpose
- Use descriptive component names
- Separate presentation logic from business logic
- Use composition over inheritance

### 2. **Performance**

- Minimize DOM updates
- Use lazy loading for large lists
- Cache expensive operations
- Optimize event handlers

### 3. **Maintainability**

- Use consistent naming conventions
- Document complex components
- Keep components small and focused
- Use type-safe data binding

### 4. **Accessibility**

- Include proper ARIA attributes
- Use semantic HTML elements
- Ensure keyboard navigation
- Provide alternative text for images

## Next Steps

- [Template Engine](engine.md) - Learn about Jinja2 templates
- [Hot Reloading](hot-reload.md) - Development workflow
- [Real-time Components](real-time.md) - WebSocket integration
- [Component Examples](../playground/components/) - Working examples

---

**Ready to build components?** Start with the basic examples above, then explore [Real-time Components](real-time.md) for interactive features.
