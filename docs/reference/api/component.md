# Component Reference

Components provide real-time, stateful UI elements that update automatically via WebSocket.

## Including Component

```crystal
class MyComponent
  include Azu::Component

  def content
    "<div>Hello</div>"
  end
end
```

## Required Methods

### content

Return the HTML content of the component.

```crystal
def content : String
  <<-HTML
  <div id="my-component">
    <p>Count: #{@count}</p>
  </div>
  HTML
end
```

**Returns:** `String` - HTML content

## Lifecycle Methods

### mount

Called when component is first connected.

```crystal
def mount(socket)
  @socket = socket
  load_initial_data
  push_state
end
```

**Parameters:**
- `socket` - WebSocket connection

### unmount

Called when component is disconnected.

```crystal
def unmount
  cleanup_subscriptions
  save_state
end
```

## Instance Methods

### push_state

Push current state to client, triggering re-render.

```crystal
on_event "increment" do
  @count += 1
  push_state  # Sends updated HTML to client
end
```

### push_append

Append content to an element.

```crystal
def add_item(item)
  @items << item
  push_append("#items-list", render_item(item))
end
```

**Parameters:**
- `selector : String` - CSS selector
- `html : String` - HTML to append

### push_prepend

Prepend content to an element.

```crystal
def add_notification(notification)
  push_prepend("#notifications", render_notification(notification))
end
```

### push_replace

Replace an element's content.

```crystal
def update_status(status)
  push_replace("#status", "<span>#{status}</span>")
end
```

### push_remove

Remove an element.

```crystal
def remove_item(id)
  @items.reject! { |i| i.id == id }
  push_remove("#item-#{id}")
end
```

## Event Handling

### on_event

Define event handlers.

```crystal
on_event "click_button" do
  handle_button_click
end

on_event "submit_form" do |data|
  name = data["name"].as_s
  process_form(name)
end
```

**Parameters:**
- `event_name : String` - Event name from client
- `&block` - Handler block (optionally receives event data)

### Client-Side Events

```html
<button azu-click="click_button">Click Me</button>
<button azu-click="delete" azu-value="123">Delete</button>
<input azu-change="input_changed" azu-model="name">
<form azu-submit="submit_form">...</form>
```

**Event Attributes:**
- `azu-click` - Click event
- `azu-change` - Change event
- `azu-submit` - Form submit
- `azu-keyup` - Key up event
- `azu-keydown` - Key down event
- `azu-focus` - Focus event
- `azu-blur` - Blur event

**Data Attributes:**
- `azu-value` - Value to send with event
- `azu-model` - Two-way data binding

## Properties

### property

Define component properties.

```crystal
class UserComponent
  include Azu::Component

  property user_id : Int64
  property show_details : Bool = false

  def mount(socket)
    @user = User.find(user_id)
    push_state
  end
end
```

Usage in HTML:
```html
<div azu-component="UserComponent" azu-props='{"user_id": 123, "show_details": true}'></div>
```

## State Management

```crystal
class CounterComponent
  include Azu::Component

  @count = 0
  @history = [] of Int32

  def content
    <<-HTML
    <div>
      <p>Count: #{@count}</p>
      <button azu-click="increment">+</button>
      <button azu-click="decrement">-</button>
      <button azu-click="reset">Reset</button>
    </div>
    HTML
  end

  on_event "increment" do
    @history << @count
    @count += 1
    push_state
  end

  on_event "decrement" do
    @history << @count
    @count -= 1
    push_state
  end

  on_event "reset" do
    @history.clear
    @count = 0
    push_state
  end
end
```

## Registration

### Registering with Spark

```crystal
Azu::Spark.register(MyComponent)
Azu::Spark.register(CounterComponent)
Azu::Spark.register(UserComponent)
```

## Client Setup

### JavaScript Connection

```html
<script src="/azu/spark.js"></script>
<script>
  document.addEventListener('DOMContentLoaded', function() {
    Spark.connect('/spark');
  });
</script>
```

### Component Mounting

```html
<div azu-component="CounterComponent"></div>
<div azu-component="UserComponent" azu-props='{"user_id": 42}'></div>
```

## Complete Example

```crystal
class TodoComponent
  include Azu::Component

  @todos = [] of Todo
  @new_todo = ""

  def mount(socket)
    @todos = Todo.all
    push_state
  end

  def content
    <<-HTML
    <div class="todo-app">
      <h1>Todos (#{@todos.size})</h1>

      <form azu-submit="add_todo">
        <input type="text"
               azu-model="new_todo"
               value="#{@new_todo}"
               placeholder="What needs to be done?">
        <button type="submit">Add</button>
      </form>

      <ul id="todo-list">
        #{@todos.map { |t| render_todo(t) }.join}
      </ul>
    </div>
    HTML
  end

  private def render_todo(todo : Todo)
    <<-HTML
    <li id="todo-#{todo.id}" class="#{todo.completed? ? "completed" : ""}">
      <input type="checkbox"
             azu-change="toggle"
             azu-value="#{todo.id}"
             #{todo.completed? ? "checked" : ""}>
      <span>#{todo.title}</span>
      <button azu-click="delete" azu-value="#{todo.id}">×</button>
    </li>
    HTML
  end

  on_event "new_todo_change" do |value|
    @new_todo = value.as_s
  end

  on_event "add_todo" do
    unless @new_todo.empty?
      todo = Todo.create!(title: @new_todo)
      @todos << todo
      @new_todo = ""
      push_state
    end
  end

  on_event "toggle" do |id|
    if todo = @todos.find { |t| t.id == id.as_i64 }
      todo.toggle!
      push_replace("#todo-#{todo.id}", render_todo(todo))
    end
  end

  on_event "delete" do |id|
    @todos.reject! { |t| t.id == id.as_i64 }
    push_remove("#todo-#{id}")
  end
end
```

## See Also

- [Channel Reference](channel.md)
- [How to Build Live Component](../../how-to/real-time/build-live-component.md)
