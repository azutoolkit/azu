# Building Live Components

This tutorial teaches you how to create real-time, interactive UI components using Azu's live component system.

## What You'll Build

By the end of this tutorial, you'll have:

- A reactive counter component
- A live chat component
- Understanding of component lifecycle
- Real-time DOM updates without page refreshes

## Prerequisites

- Completed [Adding WebSockets](adding-websockets.md) tutorial
- Understanding of WebSocket basics

## Step 1: Understanding Live Components

Live components in Azu provide:

- **Real-time DOM updates** - UI changes without page refreshes
- **Server-side state** - State managed on the server
- **Event-driven interactions** - Respond to user actions immediately
- **Automatic synchronization** - Server and client stay in sync

## Step 2: Create a Counter Component

Create `src/components/counter_component.cr`:

```crystal
class CounterComponent < Azu::Component
  def initialize(@initial_count : Int32 = 0)
    @count = @initial_count
  end

  def content
    div class: "counter", id: "counter-#{object_id}" do
      h3 "Counter"

      div class: "display" do
        span id: "count", class: "count-value" do
          text @count.to_s
        end
      end

      div class: "controls" do
        button onclick: "increment()", class: "btn btn-primary" do
          text "+"
        end
        button onclick: "decrement()", class: "btn btn-secondary" do
          text "-"
        end
        button onclick: "reset()", class: "btn btn-danger" do
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

## Step 3: Create a Counter Endpoint

Create `src/endpoints/counter_endpoint.cr`:

```crystal
struct CounterEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Html)
  include Azu::Templates::Renderable

  get "/counter"

  def call
    component = CounterComponent.new(0)

    html <<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>Live Counter</title>
        <style>
          .counter { text-align: center; padding: 20px; }
          .count-value { font-size: 48px; font-weight: bold; }
          .controls { margin-top: 20px; }
          .btn { padding: 10px 20px; margin: 5px; cursor: pointer; }
          .btn-primary { background: #007bff; color: white; border: none; }
          .btn-secondary { background: #6c757d; color: white; border: none; }
          .btn-danger { background: #dc3545; color: white; border: none; }
        </style>
      </head>
      <body>
        #{component.render}

        <script>
          const ws = new WebSocket('ws://localhost:4000/spark');

          function increment() {
            ws.send(JSON.stringify({type: 'event', event: 'increment'}));
          }

          function decrement() {
            ws.send(JSON.stringify({type: 'event', event: 'decrement'}));
          }

          function reset() {
            ws.send(JSON.stringify({type: 'event', event: 'reset'}));
          }

          ws.onmessage = function(event) {
            const data = JSON.parse(event.data);
            if (data.type === 'update') {
              document.getElementById(data.id).innerHTML = data.content;
            }
          };
        </script>
      </body>
      </html>
    HTML
  end
end
```

## Step 4: Create a Chat Component

Create `src/components/chat_component.cr`:

```crystal
class ChatComponent < Azu::Component
  def initialize(@room_id : String)
    @messages = [] of NamedTuple(user: String, text: String, time: Time)
    @users = Set(String).new
  end

  def content
    div class: "chat-room", id: "chat-#{object_id}" do
      div class: "chat-header" do
        h3 "Room: #{@room_id}"
        span id: "user-count" do
          text "#{@users.size} users"
        end
      end

      div id: "messages", class: "messages" do
        @messages.each do |msg|
          render_message(msg)
        end
      end

      form onsubmit: "sendMessage(event)", class: "message-form" do
        input type: "text", id: "message-input", placeholder: "Type a message..."
        button type: "submit" do
          text "Send"
        end
      end
    end
  end

  def on_event("send_message", data)
    message = data["text"]?.try(&.as_s)
    user = data["user"]?.try(&.as_s) || "Anonymous"
    return unless message && !message.strip.empty?

    msg = {user: user, text: message, time: Time.utc}
    @messages << msg

    # Append new message to DOM
    append_element "messages", render_message_html(msg)
  end

  def on_event("user_joined", data)
    user = data["user"]?.try(&.as_s)
    return unless user

    @users << user
    update_element "user-count", "#{@users.size} users"

    # Add system message
    append_element "messages", <<-HTML
      <div class="system-message">#{user} joined the room</div>
    HTML
  end

  def on_event("user_left", data)
    user = data["user"]?.try(&.as_s)
    return unless user

    @users.delete(user)
    update_element "user-count", "#{@users.size} users"

    append_element "messages", <<-HTML
      <div class="system-message">#{user} left the room</div>
    HTML
  end

  private def render_message(msg)
    div class: "message" do
      span class: "user" do
        text msg[:user]
      end
      span class: "text" do
        text msg[:text]
      end
      time class: "timestamp" do
        text msg[:time].to_s("%H:%M")
      end
    end
  end

  private def render_message_html(msg)
    <<-HTML
      <div class="message">
        <span class="user">#{msg[:user]}</span>
        <span class="text">#{msg[:text]}</span>
        <time class="timestamp">#{msg[:time].to_s("%H:%M")}</time>
      </div>
    HTML
  end
end
```

## Step 5: Component Lifecycle

Components have lifecycle methods you can override:

```crystal
class LifecycleComponent < Azu::Component
  def on_mount
    # Called when component is first mounted
    # Load initial data, set up subscriptions
    Log.info { "Component mounted" }
  end

  def on_unmount
    # Called when component is removed
    # Clean up resources, unsubscribe
    Log.info { "Component unmounted" }
  end

  def on_connect
    # Called when WebSocket connects
    Log.info { "WebSocket connected" }
  end

  def on_disconnect
    # Called when WebSocket disconnects
    Log.info { "WebSocket disconnected" }
  end
end
```

## Step 6: State Management

Manage complex state in components:

```crystal
class StatefulComponent < Azu::Component
  def initialize
    @state = {} of String => JSON::Any
    @listeners = [] of Proc(Nil)
  end

  # Get state value
  def get(key : String)
    @state[key]?
  end

  # Set state and notify listeners
  def set(key : String, value)
    @state[key] = JSON::Any.new(value)
    notify_listeners
    render_state
  end

  # Subscribe to state changes
  def subscribe(&block : -> Nil)
    @listeners << block
  end

  def on_event("update_state", data)
    key = data["key"]?.try(&.as_s)
    value = data["value"]?
    return unless key && value

    set(key, value)
  end

  private def notify_listeners
    @listeners.each(&.call)
  end

  private def render_state
    content = @state.map do |k, v|
      "<div><strong>#{k}:</strong> #{v}</div>"
    end.join

    update_element "state-display", content
  end
end
```

## Step 7: Form Components

Handle forms with validation:

```crystal
class FormComponent < Azu::Component
  def initialize
    @errors = {} of String => String
    @values = {} of String => String
  end

  def content
    form onsubmit: "submitForm(event)", id: "user-form" do
      div class: "form-group" do
        label "Name", for: "name"
        input type: "text", id: "name", name: "name", value: @values["name"]?

        if error = @errors["name"]?
          span class: "error" do
            text error
          end
        end
      end

      div class: "form-group" do
        label "Email", for: "email"
        input type: "email", id: "email", name: "email", value: @values["email"]?

        if error = @errors["email"]?
          span class: "error" do
            text error
          end
        end
      end

      button type: "submit" do
        text "Submit"
      end
    end
  end

  def on_event("submit_form", data)
    @values = data.as_h.transform_values(&.as_s)
    @errors.clear

    validate_form

    if @errors.empty?
      process_form
    else
      render_errors
    end
  end

  private def validate_form
    name = @values["name"]?
    email = @values["email"]?

    @errors["name"] = "Name is required" if name.nil? || name.strip.empty?
    @errors["email"] = "Email is required" if email.nil? || email.strip.empty?
    @errors["email"] = "Invalid email" if email && !email.includes?("@")
  end

  private def render_errors
    @errors.each do |field, message|
      # Show error next to field
      update_element "#{field}-error", message
    end
  end

  private def process_form
    # Handle successful submission
    update_element "user-form", <<-HTML
      <div class="success">Form submitted successfully!</div>
    HTML
  end
end
```

## Step 8: Composing Components

Build complex UIs by composing components:

```crystal
class ButtonComponent < Azu::Component
  def initialize(@text : String, @variant : String = "primary")
  end

  def content
    button class: "btn btn-#{@variant}" do
      text @text
    end
  end
end

class CardComponent < Azu::Component
  def initialize(@title : String, &@block : -> Nil)
  end

  def content
    div class: "card" do
      div class: "card-header" do
        h4 @title
      end
      div class: "card-body" do
        @block.call
      end
    end
  end
end

class UserCardComponent < Azu::Component
  def initialize(@user : User)
  end

  def content
    CardComponent.new(@user.name) do
      p @user.email
      p "Joined: #{@user.created_at.to_s("%B %Y")}"

      div class: "actions" do
        ButtonComponent.new("Edit", "primary").render
        ButtonComponent.new("Delete", "danger").render
      end
    end.render
  end
end
```

## Key Concepts Learned

### Component Structure

```crystal
class MyComponent < Azu::Component
  def content       # Define the HTML structure
  def on_event(...)  # Handle events from client
  def on_mount       # Called when mounted
  def on_unmount     # Called when removed
end
```

### DOM Updates

```crystal
update_element "id", "new content"  # Replace element content
append_element "id", "html"         # Append to element
remove_element "id"                 # Remove element
```

### Event Handling

```crystal
def on_event("event_name", data)
  # data is a JSON::Any with event payload
  value = data["key"]?.try(&.as_s)
end
```

## Best Practices

1. **Keep components focused** - One responsibility per component
2. **Use composition** - Build complex UIs from simple components
3. **Handle cleanup** - Implement `on_unmount` for resource cleanup
4. **Validate inputs** - Always validate event data
5. **Minimize state** - Keep component state as simple as possible

## Next Steps

You've learned to build interactive components. Continue with:

- [Testing Your App](testing-your-app.md) - Test your components
- [Deploying to Production](deploying-to-production.md) - Deploy your application

---

**Interactive components ready!** Your application now has real-time, reactive UI elements.
