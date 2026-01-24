# Understanding Components

This document explains Azu's live component system, which enables real-time, stateful UI updates without writing JavaScript.

## What are Components?

Components are server-side objects that:
- Maintain state on the server
- Render HTML
- Respond to user events
- Push updates to the browser

```crystal
class CounterComponent
  include Azu::Component

  @count = 0

  def content
    <<-HTML
    <div>
      <span>Count: #{@count}</span>
      <button azu-click="increment">+</button>
    </div>
    HTML
  end

  on_event "increment" do
    @count += 1
    push_state
  end
end
```

## How Components Work

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                     Browser                         │
│  ┌─────────────────────────────────────────────┐   │
│  │              Rendered HTML                   │   │
│  │  <button azu-click="increment">+</button>   │   │
│  └─────────────────────────────────────────────┘   │
│         │                    ↑                      │
│         │ Click Event        │ HTML Patch           │
│         ↓                    │                      │
│  ┌─────────────────────────────────────────────┐   │
│  │           Spark JavaScript                   │   │
│  └─────────────────────────────────────────────┘   │
│         │                    ↑                      │
│         │ WebSocket          │ WebSocket            │
└─────────│────────────────────│──────────────────────┘
          ↓                    │
┌─────────────────────────────────────────────────────┐
│                      Server                         │
│  ┌─────────────────────────────────────────────┐   │
│  │            CounterComponent                  │   │
│  │            @count = 5                        │   │
│  │                                              │   │
│  │  on_event "increment" → @count += 1         │   │
│  │                       → push_state           │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### Event Flow

1. User clicks button in browser
2. Spark JS sends event via WebSocket
3. Server component receives event
4. Component updates state
5. Component re-renders HTML
6. Server sends HTML diff to browser
7. Spark JS patches the DOM

## Component Lifecycle

```crystal
class MyComponent
  include Azu::Component

  def mount(socket)
    # Called when component first connects
    # Load initial data
    @data = load_data
    push_state
  end

  def unmount
    # Called when component disconnects
    # Clean up resources
  end

  def content
    # Called to render HTML
  end
end
```

### Lifecycle Stages

```
mount → content → [events/updates] → content → ... → unmount
```

## State Management

### Component State

State lives in instance variables:

```crystal
class TodoComponent
  include Azu::Component

  @todos = [] of Todo
  @new_todo = ""

  def content
    # Uses @todos and @new_todo
  end
end
```

### Updating State

Update state and push to client:

```crystal
on_event "add_todo" do
  @todos << Todo.new(@new_todo)
  @new_todo = ""
  push_state  # Re-render and send to client
end
```

## Event Handling

### Event Attributes

Connect HTML to component events:

```html
<button azu-click="delete">Delete</button>
<input azu-change="update_name">
<form azu-submit="save">
```

### Event Data

Send data with events:

```html
<button azu-click="delete" azu-value="123">Delete Item 123</button>
```

```crystal
on_event "delete" do |id|
  @items.reject! { |i| i.id == id.as_i }
  push_state
end
```

### Two-Way Binding

Bind form inputs:

```html
<input azu-model="name" value="#{@name}">
```

The `@name` variable updates when the input changes.

## Optimized Updates

### Full Re-render

`push_state` re-renders the entire component:

```crystal
on_event "change" do
  @data = new_data
  push_state  # Full re-render
end
```

### Partial Updates

For performance, update only parts:

```crystal
on_event "add_item" do
  item = create_item
  @items << item

  # Only append the new item
  push_append("#items-list", render_item(item))
end

on_event "remove_item" do |id|
  @items.reject! { |i| i.id == id.as_i }

  # Only remove that element
  push_remove("#item-#{id}")
end
```

## Props and Initialization

### Component Properties

Pass initial data to components:

```crystal
class UserCardComponent
  include Azu::Component

  property user_id : Int64

  def mount(socket)
    @user = User.find(user_id)
    push_state
  end
end
```

### HTML Mounting

```html
<div azu-component="UserCardComponent"
     azu-props='{"user_id": 42}'></div>
```

## Real-Time Updates

### Server-Initiated Updates

Components can receive updates from server events:

```crystal
class DashboardComponent
  include Azu::Component

  def mount(socket)
    # Subscribe to data changes
    EventBus.subscribe(:order_created) do |order|
      @orders.unshift(order)
      push_state
    end
  end
end
```

### Periodic Updates

Update on intervals:

```crystal
def mount(socket)
  spawn do
    loop do
      @stats = fetch_stats
      push_state
      sleep 30.seconds
    end
  end
end
```

## Component Communication

### Parent-Child

Nest components and pass events up:

```crystal
# Child emits event
<button azu-click="item_selected" azu-value="#{item.id}">Select</button>

# Parent listens
<div azu-component="ChildComponent"
     azu-on-item_selected="handle_selection"></div>
```

### Global Events

Use a message bus:

```crystal
# Component A
on_event "filter_changed" do |filter|
  EventBus.publish(:filter, filter)
end

# Component B
def mount(socket)
  EventBus.subscribe(:filter) do |filter|
    @current_filter = filter
    push_state
  end
end
```

## When to Use Components

### Good Use Cases

- Interactive forms
- Real-time dashboards
- Live search/filtering
- Chat interfaces
- Notifications
- Dynamic lists

### When to Use Plain Endpoints

- Static content
- Simple forms with redirects
- API responses
- File downloads

## See Also

- [Real-Time](real-time.md)
- [Component Reference](../../reference/api/component.md)
- [How to Build Live Component](../../how-to/real-time/build-live-component.md)
