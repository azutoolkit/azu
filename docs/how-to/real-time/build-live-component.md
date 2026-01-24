# How to Build a Live Component

This guide shows you how to create real-time UI components that update automatically.

## Basic Live Component

Create a component by including `Azu::Component`:

```crystal
class CounterComponent
  include Azu::Component

  @count = 0

  def mount(socket)
    # Called when component is mounted
    push_state
  end

  def content
    <<-HTML
    <div id="counter">
      <span>Count: #{@count}</span>
      <button azu-click="increment">+</button>
      <button azu-click="decrement">-</button>
    </div>
    HTML
  end

  on_event "increment" do
    @count += 1
    push_state
  end

  on_event "decrement" do
    @count -= 1
    push_state
  end
end
```

## Register Component with Spark

Add your component to the Spark system:

```crystal
# In your application setup
Azu::Spark.register(CounterComponent)
```

## Client-Side Setup

Include the Spark JavaScript client:

```html
<script src="/azu/spark.js"></script>
<script>
  Spark.connect('/spark');
</script>
```

Mount a component in your HTML:

```html
<div azu-component="CounterComponent"></div>
```

## Component with Props

Pass initial data to components:

```crystal
class UserCardComponent
  include Azu::Component

  property user_id : Int64
  @user : User?

  def mount(socket)
    @user = User.find(user_id)
    push_state
  end

  def content
    if user = @user
      <<-HTML
      <div class="user-card">
        <h3>#{user.name}</h3>
        <p>#{user.email}</p>
      </div>
      HTML
    else
      "<div>User not found</div>"
    end
  end
end
```

Mount with props:

```html
<div azu-component="UserCardComponent" azu-props='{"user_id": 123}'></div>
```

## Handling Form Input

Create interactive forms:

```crystal
class TodoFormComponent
  include Azu::Component

  @todos = [] of String
  @input = ""

  def content
    <<-HTML
    <div id="todo-form">
      <input type="text"
             azu-model="input"
             value="#{@input}"
             placeholder="Add todo...">
      <button azu-click="add_todo">Add</button>

      <ul>
        #{@todos.map { |todo| "<li>#{todo}</li>" }.join}
      </ul>
    </div>
    HTML
  end

  on_event "input_change" do |value|
    @input = value.as_s
  end

  on_event "add_todo" do
    unless @input.empty?
      @todos << @input
      @input = ""
      push_state
    end
  end
end
```

## Component Lifecycle

Handle lifecycle events:

```crystal
class LifecycleComponent
  include Azu::Component

  def mount(socket)
    # Called when component first mounts
    load_initial_data
  end

  def unmount
    # Called when component is removed
    cleanup_resources
  end

  def before_update
    # Called before state update
  end

  def after_update
    # Called after state update
  end

  private def load_initial_data
    # Load data from database, etc.
  end

  private def cleanup_resources
    # Clean up subscriptions, etc.
  end
end
```

## Real-time Updates

Push updates from server events:

```crystal
class NotificationComponent
  include Azu::Component

  @notifications = [] of Notification

  def mount(socket)
    # Subscribe to notification channel
    NotificationService.subscribe(current_user_id) do |notification|
      @notifications.unshift(notification)
      push_state
    end
  end

  def content
    <<-HTML
    <div class="notifications">
      #{@notifications.map { |n| render_notification(n) }.join}
    </div>
    HTML
  end

  private def render_notification(n : Notification)
    <<-HTML
    <div class="notification #{n.read? ? "" : "unread"}">
      <p>#{n.message}</p>
      <button azu-click="dismiss" azu-value="#{n.id}">Dismiss</button>
    </div>
    HTML
  end

  on_event "dismiss" do |id|
    @notifications.reject! { |n| n.id == id.as_i }
    push_state
  end
end
```

## Optimizing Updates

Use partial updates for better performance:

```crystal
class ListComponent
  include Azu::Component

  @items = [] of Item

  def content
    <<-HTML
    <ul id="item-list">
      #{@items.map { |item| render_item(item) }.join}
    </ul>
    HTML
  end

  on_event "add_item" do |data|
    item = Item.new(data["name"].as_s)
    @items << item

    # Push only the new item instead of full re-render
    push_append("#item-list", render_item(item))
  end

  private def render_item(item : Item)
    %(<li id="item-#{item.id}">#{item.name}</li>)
  end
end
```

## Component Communication

Components can communicate via events:

```crystal
class ParentComponent
  include Azu::Component

  @selected_id : Int64?

  def content
    <<-HTML
    <div>
      <div azu-component="ListComponent" azu-on-select="handle_select"></div>
      <div azu-component="DetailComponent" azu-props='{"id": #{@selected_id}}'></div>
    </div>
    HTML
  end

  on_event "handle_select" do |id|
    @selected_id = id.as_i64
    push_state
  end
end
```

## Error Handling

Handle component errors gracefully:

```crystal
class SafeComponent
  include Azu::Component

  @error : String?

  def content
    if error = @error
      %(<div class="error">#{error}</div>)
    else
      render_content
    end
  end

  on_event "risky_action" do
    begin
      perform_risky_action
    rescue ex
      @error = "Something went wrong: #{ex.message}"
      push_state
    end
  end
end
```

## See Also

- [Create WebSocket Channel](create-websocket-channel.md)
- [Broadcast Messages](broadcast-messages.md)
