# Components

Azu's component system provides a powerful way to build interactive, real-time UI components. With type safety, automatic updates, and efficient rendering, components make building dynamic web applications straightforward and maintainable.

## What are Components?

Components in Azu are:

- **Interactive UI Elements**: Reusable, stateful UI components
- **Real-time Updates**: Automatic updates when state changes
- **Type Safe**: Compile-time type safety for component state
- **Efficient**: Minimal re-rendering and optimal performance
- **Testable**: Easy to test and validate

## Basic Component

```crystal
class CounterComponent
  include Azu::Component

  @count = 0

  def content
    div class: "counter" do
      h2 { text "Counter: #{@count}" }
      button "Increment", onclick: "increment"
      button "Decrement", onclick: "decrement"
      button "Reset", onclick: "reset"
    end
  end

  def on_event("increment", data)
    @count += 1
    update!
  end

  def on_event("decrement", data)
    @count -= 1
    update!
  end

  def on_event("reset", data)
    @count = 0
    update!
  end
end
```

## Component Lifecycle

### Mounting

```crystal
class LifecycleComponent
  include Azu::Component

  def initialize(@user : User)
    @mounted_at = Time.utc
    @update_count = 0
  end

  def content
    div class: "lifecycle-component" do
      h3 { text "Component Lifecycle" }
      p { text "Mounted at: #{@mounted_at.to_rfc3339}" }
      p { text "Update count: #{@update_count}" }
      p { text "Age: #{age}" }
    end
  end

  def on_mount
    Log.info { "Component mounted: #{self.class.name}" }
    @mounted_at = Time.utc
  end

  def on_update
    @update_count += 1
    Log.info { "Component updated: #{@update_count} times" }
  end

  def on_unmount
    Log.info { "Component unmounted: #{self.class.name}" }
  end

  private def age
    Time.utc - @mounted_at
  end
end
```

### State Management

```crystal
class StatefulComponent
  include Azu::Component

  def initialize(@initial_state : Hash(String, JSON::Any))
    @state = @initial_state.dup
    @listeners = [] of Proc(String, JSON::Any, Nil)
  end

  def content
    div class: "stateful-component" do
      h3 { text "Stateful Component" }

      @state.each do |key, value|
        div class: "state-item" do
          span { text "#{key}: " }
          span { text value.to_s }
          button "Update", onclick: "update_#{key}"
        end
      end
    end
  end

  def on_event("update_name", data)
    @state["name"] = JSON::Any.new(data["value"].as_s)
    notify_listeners("name", @state["name"])
    update!
  end

  def on_event("update_email", data)
    @state["email"] = JSON::Any.new(data["value"].as_s)
    notify_listeners("email", @state["email"])
    update!
  end

  def add_listener(&block : String, JSON::Any -> Nil)
    @listeners << block
  end

  private def notify_listeners(key : String, value : JSON::Any)
    @listeners.each do |listener|
      listener.call(key, value)
    end
  end
end
```

## Event Handling

### Client Events

```crystal
class EventComponent
  include Azu::Component

  def content
    div class: "event-component" do
      h3 { text "Event Handling" }

      # Form events
      form onsubmit: "handle_submit" do
        input type: "text", name: "name", placeholder: "Enter name"
        input type: "email", name: "email", placeholder: "Enter email"
        button type: "submit", text: "Submit"
      end

      # Click events
      button "Click me", onclick: "handle_click"

      # Input events
      input type: "text", oninput: "handle_input", placeholder: "Type something"

      # Custom events
      button "Custom Event", onclick: "trigger_custom"
    end
  end

  def on_event("handle_submit", data)
    name = data["name"]?.try(&.as_s) || ""
    email = data["email"]?.try(&.as_s) || ""

    # Process form submission
    process_form(name, email)
  end

  def on_event("handle_click", data)
    # Handle click event
    Log.info { "Button clicked" }
    update!
  end

  def on_event("handle_input", data)
    value = data["value"]?.try(&.as_s) || ""

    # Handle input change
    Log.info { "Input changed: #{value}" }
  end

  def on_event("trigger_custom", data)
    # Trigger custom event
    trigger_event("custom_event", {message: "Custom event triggered"})
  end

  private def process_form(name : String, email : String)
    # Process form data
    Log.info { "Form submitted: #{name} - #{email}" }
  end
end
```

### Server Events

```crystal
class ServerEventComponent
  include Azu::Component

  def content
    div class: "server-event-component" do
      h3 { text "Server Events" }
      p { text "Last server event: #{@last_server_event}" }
      button "Request Server Event", onclick: "request_server_event"
    end
  end

  def on_event("request_server_event", data)
    # Request server event
    spawn request_server_event
  end

  def on_server_event(event_type : String, data : JSON::Any)
    case event_type
    when "user_updated"
      handle_user_update(data)
    when "notification"
      handle_notification(data)
    when "error"
      handle_error(data)
    end
  end

  private def request_server_event
    # Simulate server event
    sleep 1.second
    trigger_server_event("user_updated", {
      user_id: 123,
      name: "Updated User",
      timestamp: Time.utc.to_rfc3339
    })
  end

  private def handle_user_update(data : JSON::Any)
    @last_server_event = "User updated: #{data["name"]}"
    update!
  end

  private def handle_notification(data : JSON::Any)
    @last_server_event = "Notification: #{data["message"]}"
    update!
  end

  private def handle_error(data : JSON::Any)
    @last_server_event = "Error: #{data["message"]}"
    update!
  end
end
```

## Component Composition

### Parent-Child Components

```crystal
class ParentComponent
  include Azu::Component

  def initialize(@user : User)
    @child_components = [] of ChildComponent
  end

  def content
    div class: "parent-component" do
      h2 { text "Parent Component" }
      p { text "User: #{@user.name}" }

      # Child components
      @child_components.each do |child|
        child.render
      end

      # Add child component button
      button "Add Child", onclick: "add_child"
    end
  end

  def on_event("add_child", data)
    child = ChildComponent.new(@user)
    @child_components << child
    update!
  end

  def on_event("remove_child", data)
    child_id = data["child_id"]?.try(&.as_i64)
    @child_components.reject! { |child| child.id == child_id }
    update!
  end
end

class ChildComponent
  include Azu::Component

  def initialize(@user : User)
    @created_at = Time.utc
  end

  def content
    div class: "child-component" do
      h3 { text "Child Component" }
      p { text "Created at: #{@created_at.to_rfc3339}" }
      p { text "User: #{@user.name}" }
      button "Remove", onclick: "remove_self"
    end
  end

  def on_event("remove_self", data)
    # Notify parent to remove this component
    trigger_event("remove_child", {child_id: @id})
  end
end
```

### Component Communication

```crystal
class CommunicationComponent
  include Azu::Component

  def initialize(@message_bus : MessageBus)
    @message_bus = @message_bus
    @message_bus.subscribe("user_updated", method(:handle_user_update))
  end

  def content
    div class: "communication-component" do
      h3 { text "Component Communication" }
      p { text "Last message: #{@last_message}" }
      button "Send Message", onclick: "send_message"
    end
  end

  def on_event("send_message", data)
    message = data["message"]?.try(&.as_s) || "Hello from component!"
    @message_bus.publish("component_message", {message: message})
  end

  def handle_user_update(data : JSON::Any)
    @last_message = "User updated: #{data["name"]}"
    update!
  end

  def on_unmount
    @message_bus.unsubscribe("user_updated", method(:handle_user_update))
  end
end
```

## Component Testing

### Unit Testing

```crystal
require "spec"

describe CounterComponent do
  it "initializes with zero count" do
    component = CounterComponent.new
    component.count.should eq(0)
  end

  it "increments count on increment event" do
    component = CounterComponent.new
    component.on_event("increment", {})
    component.count.should eq(1)
  end

  it "decrements count on decrement event" do
    component = CounterComponent.new
    component.on_event("increment", {})
    component.on_event("decrement", {})
    component.count.should eq(0)
  end

  it "resets count on reset event" do
    component = CounterComponent.new
    component.on_event("increment", {})
    component.on_event("increment", {})
    component.on_event("reset", {})
    component.count.should eq(0)
  end
end
```

### Integration Testing

```crystal
describe "Component Integration" do
  it "handles multiple events" do
    component = CounterComponent.new

    # Simulate multiple events
    component.on_event("increment", {})
    component.on_event("increment", {})
    component.on_event("decrement", {})

    component.count.should eq(1)
  end

  it "handles event with data" do
    component = StatefulComponent.new({})

    component.on_event("update_name", {value: "Alice"})

    component.state["name"].should eq(JSON::Any.new("Alice"))
  end
end
```

## Performance Optimization

### Lazy Rendering

```crystal
class LazyComponent
  include Azu::Component

  def initialize(@items : Array(Item))
    @visible_items = [] of Item
    @page_size = 10
    @current_page = 0
  end

  def content
    div class: "lazy-component" do
      h3 { text "Lazy Loading Component" }

      # Render visible items
      @visible_items.each do |item|
        render_item(item)
      end

      # Load more button
      if has_more_items?
        button "Load More", onclick: "load_more"
      end
    end
  end

  def on_event("load_more", data)
    load_next_page
    update!
  end

  private def load_next_page
    start_index = @current_page * @page_size
    end_index = start_index + @page_size

    new_items = @items[start_index...end_index]
    @visible_items.concat(new_items)
    @current_page += 1
  end

  private def has_more_items? : Bool
    @current_page * @page_size < @items.size
  end

  private def render_item(item : Item)
    div class: "item" do
      h4 { text item.name }
      p { text item.description }
    end
  end
end
```

### Memoization

```crystal
class MemoizedComponent
  include Azu::Component

  def initialize(@data : Array(DataItem))
    @memoized_results = {} of String => JSON::Any
  end

  def content
    div class: "memoized-component" do
      h3 { text "Memoized Component" }

      # Use memoized results
      @data.each do |item|
        result = get_memoized_result(item)
        render_item(item, result)
      end
    end
  end

  private def get_memoized_result(item : DataItem) : JSON::Any
    cache_key = "#{item.id}_#{item.updated_at}"

    if cached = @memoized_results[cache_key]?
      cached
    else
      result = expensive_calculation(item)
      @memoized_results[cache_key] = result
      result
    end
  end

  private def expensive_calculation(item : DataItem) : JSON::Any
    # Expensive calculation
    sleep 0.1.seconds
    JSON::Any.new({
      processed: true,
      value: item.value * 2,
      timestamp: Time.utc.to_rfc3339
    })
  end
end
```

## Component State Management

### Global State

```crystal
class GlobalStateComponent
  include Azu::Component

  def initialize(@global_state : GlobalState)
    @global_state.subscribe("user_updated", method(:handle_user_update))
  end

  def content
    div class: "global-state-component" do
      h3 { text "Global State Component" }
      p { text "Current user: #{@global_state.current_user.name}" }
      p { text "Theme: #{@global_state.theme}" }

      button "Toggle Theme", onclick: "toggle_theme"
    end
  end

  def on_event("toggle_theme", data)
    new_theme = @global_state.theme == "light" ? "dark" : "light"
    @global_state.set_theme(new_theme)
  end

  def handle_user_update(data : JSON::Any)
    # Handle global state change
    update!
  end
end
```

### Local State

```crystal
class LocalStateComponent
  include Azu::Component

  def initialize
    @local_state = {
      "counter" => JSON::Any.new(0),
      "message" => JSON::Any.new(""),
      "is_loading" => JSON::Any.new(false)
    }
  end

  def content
    div class: "local-state-component" do
      h3 { text "Local State Component" }

      # Counter
      p { text "Counter: #{@local_state["counter"]}" }
      button "Increment", onclick: "increment"

      # Message
      input type: "text", value: @local_state["message"].as_s, oninput: "update_message"

      # Loading state
      if @local_state["is_loading"].as_bool
        p { text "Loading..." }
      else
        button "Load Data", onclick: "load_data"
      end
    end
  end

  def on_event("increment", data)
    current = @local_state["counter"].as_i
    @local_state["counter"] = JSON::Any.new(current + 1)
    update!
  end

  def on_event("update_message", data)
    message = data["value"]?.try(&.as_s) || ""
    @local_state["message"] = JSON::Any.new(message)
    update!
  end

  def on_event("load_data", data)
    @local_state["is_loading"] = JSON::Any.new(true)
    update!

    # Simulate async operation
    spawn load_data_async
  end

  private def load_data_async
    sleep 2.seconds
    @local_state["is_loading"] = JSON::Any.new(false)
    @local_state["message"] = JSON::Any.new("Data loaded!")
    update!
  end
end
```

## Best Practices

### 1. Keep Components Simple

```crystal
# Good: Simple, focused component
class UserCardComponent
  include Azu::Component

  def initialize(@user : User)
  end

  def content
    div class: "user-card" do
      h3 { text @user.name }
      p { text @user.email }
    end
  end
end

# Avoid: Complex component with multiple responsibilities
class ComplexComponent
  include Azu::Component

  def content
    # User management
    # Post management
    # Comment management
    # Notification management
    # Too many responsibilities!
  end
end
```

### 2. Use Composition

```crystal
# Good: Compose simple components
class UserProfileComponent
  include Azu::Component

  def content
    div class: "user-profile" do
      UserCardComponent.new(@user).render
      UserPostsComponent.new(@user).render
      UserCommentsComponent.new(@user).render
    end
  end
end
```

### 3. Handle Errors Gracefully

```crystal
class ErrorHandlingComponent
  include Azu::Component

  def content
    div class: "error-handling-component" do
      if @error
        div class: "error" do
          text "Error: #{@error}"
        end
      else
        # Normal content
      end
    end
  end

  def on_event("risky_operation", data)
    begin
      perform_risky_operation(data)
    rescue e
      @error = e.message
      update!
    end
  end
end
```

### 4. Use Type Safety

```crystal
class TypeSafeComponent
  include Azu::Component

  def initialize(@user : User, @settings : UserSettings)
    # Type-safe initialization
  end

  def on_event("update_settings", data)
    # Type-safe event handling
    settings = UserSettings.from_json(data.to_json)
    @settings = settings
    update!
  end
end
```

### 5. Test Thoroughly

```crystal
describe "Component" do
  it "handles all events correctly" do
    component = MyComponent.new

    # Test all event types
    component.on_event("event1", {})
    component.on_event("event2", {})
    component.on_event("event3", {})

    # Assert expected state
  end
end
```

## Next Steps

Now that you understand components:

1. **[Templates](templates.md)** - Use components in templates
2. **[WebSockets](websockets.md)** - Add real-time features to components
3. **[Testing](../testing.md)** - Test your components
4. **[Performance](../advanced/performance.md)** - Optimize component performance
5. **[State Management](../advanced/state-management.md)** - Advanced state management patterns

---

_Components in Azu provide a powerful way to build interactive, real-time UI elements. With type safety, automatic updates, and efficient rendering, they make building dynamic web applications straightforward and maintainable._
