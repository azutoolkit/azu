---
description: "Static HTML with `Azu::Component` and live, server-rendered views with `Azu::Spark::Component`: declarations, lifecycle, socket, bindings and testing."
---

# Component

Azu has two kinds of components:

- **`Azu::Component`** is a static piece of HTML written with the `Azu::Markup` DSL. It renders once.
- **`Azu::Spark::Component`** is a live component. Its state lives on the server, the browser sends
  events over a WebSocket, and the server pushes the HTML that changed. See
  [Spark live views](../../explanation/spark-live-views.md) for the architecture.

## Azu::Component

Include the module, describe the markup in `content`, call `render` to get a `String`.

```crystal
class Greeting
  include Azu::Component

  def initialize(@name : String)
  end

  def content
    div class: "greeting" do
      h1 "Hello #{@name}"
      tag(:p) { text "Welcome back." }
    end
  end
end

Greeting.new("Azu").render
# => "<div class='greeting'><h1>Hello Azu</h1><p>Welcome back.</p></div>"
```

Text is HTML-escaped. `raw(html)` writes markup unescaped, `text(string)` writes escaped text.
Attributes are named arguments; `true` renders a bare boolean attribute (`disabled: true`) and `false`
omits it. There is no `p` helper (it would clash with `Kernel#p`); write a paragraph with
`tag(:p) { text "..." }`.

```crystal
class SignupForm
  include Azu::Component

  def content
    form action: "/users", method: "post" do
      label "Email", for: "email"
      input type: "email", id: "email", name: "email", required: true
      button "Sign up", type: "submit", disabled: false
    end
    raw "<!-- rendered by SignupForm -->"
  end
end

SignupForm.new.render
```

A static component can be returned from an endpoint response:

```crystal
class Greeting
  include Azu::Component

  def initialize(@name : String)
  end

  def content
    h1 "Hello #{@name}"
  end
end

struct GreetingResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    Greeting.new(@name).render
  end
end

struct GreetingEndpoint
  include Azu::Endpoint(Azu::Request, GreetingResponse)

  get "/greeting/:name"

  def call : GreetingResponse
    content_type "text/html"
    GreetingResponse.new(params["name"])
  end
end
```

## Azu::Spark::Component

Inherit directly from `Azu::Spark::Component` (declarations are not inherited through intermediate
component classes), declare the inputs and state, and implement `render`.

```crystal
class Counter < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"
  state count : Int32 = 0

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  def render
    div do
      h2 "#{label}: #{count}"
      button "+1", **spark_click(:increment)
      button "+10", **spark_click(:increment, by: 10)
    end
  end
end
```

### Declarations

| Macro | Description |
| --- | --- |
| `prop name : Type [= default]` | A read-only input supplied by the page (`Spark.render`) or the parent (`live`). A prop without a default is required. Defines a getter. |
| `state name : Type = default` | Server-owned state; a default is required. Assigning a different value (`self.count += 1`) schedules a render. |
| `state name : Type = default, persist: true` | The value survives reconnects and server restarts inside a signed snapshot kept by the browser. It must be JSON serializable and not secret. |
| `assign a: 1, b: 2` | Assigns several states at once; names and value types are checked at compile time. |
| `event def name(args) : Nil` | A method the browser may trigger. Parameters are read from the payload by name and need a type restriction. Nothing else can be invoked from the client. |
| `mountable` | Allows `Azu::Spark.render` to render this component from a page. Props must be JSON serializable. |
| `container "li", class: "todo"` | Chooses the wrapping element (default `div`) and its static attributes. |

{% hint style="warning" %}
`id`, `socket`, `render`, `mount`, `unmount`, `assigns`, `handle_event` and `handle_info` cannot be used
as prop or state names.
{% endhint %}

### Lifecycle

```crystal
class Ticker < Azu::Spark::Component
  mountable

  state ticks : Int32 = 0
  state news : Array(String) = [] of String

  def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    self.ticks = params.fetch("start", Int32, 0)
    socket.subscribe("news")
    socket.every(1.second, "tick")
  end

  def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
    if message.topic == "news"
      self.news = (news + [message.payload]).last(5)
    else
      self.ticks += 1
    end
  end

  def unmount(socket : Azu::Spark::Socket) : Nil
    # Subscriptions and timers are cancelled for you; release anything else here.
  end

  def render
    div do
      span "ticks: #{ticks}"
      ul { news.each { |item| li item } }
    end
  end
end
```

| Callback | When |
| --- | --- |
| `mount(socket, params)` | On the initial HTTP render (`socket.connected?` is `false`) and again when the WebSocket joins. Initialise state, read `socket.session`, subscribe, or call `socket.reject!`. |
| `handle_info(message, socket)` | A PubSub broadcast, a timer or a `send_info` message arrived. The component renders afterwards. |
| `unmount(socket)` | The component left the page or the connection closed. |
| `render` | Describes the HTML with the `Azu::Markup` DSL. |

### Socket

`socket` (a `Azu::Spark::Socket`) is the server-side handle of the mounted component.

| Method | Description |
| --- | --- |
| `id`, `connected?` | The component id; whether a live connection exists (false while rendering the HTTP page). |
| `session` | The signed claims given to `Spark.render(..., session: {...})`. |
| `headers`, `remote_address` | Metadata of the WebSocket connection. |
| `subscribe(topic)`, `unsubscribe(topic)` | Deliver `PubSub` broadcasts of a topic to `handle_info`. |
| `broadcast(topic, payload)` | Publish to a topic; non-string payloads are encoded as JSON. |
| `send_info(payload)` | Queue a message for this component's `handle_info`. |
| `send_after(delay, payload)`, `every(interval, payload)` | Timers delivering to `handle_info`; cancelled on unmount. |
| `put_flash(kind, message)`, `clear_flash(kind = nil)`, `flash` | Short-lived messages the component can render. |
| `push_event(name, payload)` | Dispatches the DOM event `spark:<name>` on the component's element. |
| `redirect(to, replace = false)` | Navigates the browser to a path of this application. |
| `reject!(reason)` | Refuses the connection from `mount`. |

### Bindings

Bindings return a named tuple of `spark-*` attributes that you double-splat into a tag. The event
must be declared with `event def`, otherwise compilation fails.

```crystal
class Search < Azu::Spark::Component
  mountable

  state query : String = ""
  state saved : Array(String) = [] of String

  event def search(q : String) : Nil
    self.query = q
  end

  event def save : Nil
    self.saved = saved + [query]
  end

  event def remove(index : Int32) : Nil
    remaining = saved.dup
    remaining.delete_at(index) if index < remaining.size
    self.saved = remaining
  end

  def render
    div do
      input **spark_change(:search, debounce: 300), type: "text", name: "q", value: query
      form(**spark_submit(:save, disable_with: "Saving...")) do
        button "Save", type: "submit"
      end
      saved.each_with_index do |item, index|
        button "Remove #{item}", **spark_click(:remove, index: index, confirm: "Sure?")
      end
    end
  end
end
```

`spark_click`, `spark_submit`, `spark_change`, `spark_keydown`, `spark_keyup`, `spark_blur` and
`spark_focus` accept these options: `debounce: ms`, `throttle: ms`, `target: :parent | :root | "css selector"`,
`key: "Enter"`, `confirm: "text"`, `disable_with: "text"`, `optimistic_class: "css-class"` and
`delivery: "at-most-once"` (see [event delivery](../spark-client.md#events-and-delivery)). Any other
option is sent to the handler as a parameter (`index: 3` reaches `def remove(index : Int32)`).
Crystal requires double splats before named arguments: write `button "+", **spark_click(:inc), class: "btn"`.

### Child components

`live` embeds a child component, identified among its siblings by `key`. Props are checked against the
child's `prop` declarations at compile time.

```crystal
class TodoItem < Azu::Spark::Component
  container "li", class: "todo"

  prop text : String
  prop done : Bool = false

  def render
    span text, class: done ? "done" : ""
  end
end

class TodoList < Azu::Spark::Component
  mountable

  state items : Array(String) = ["Write docs", "Ship"]

  def render
    ul do
      items.each_with_index { |item, index| live TodoItem, key: index.to_s, text: item }
    end
  end
end
```

### Rendering from a page

```crystal
class Counter < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"
  state count : Int32 = 0

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  def render
    h2 "#{label}: #{count}"
  end
end

# once, at boot (tokens are signed with SPARK_SECRET: set it in production and staging)
Azu::Spark.install

# in a layout
Azu::Spark.script_tag

# in a page: the markup plus a signed token the browser uses to join
Azu::Spark.render(Counter, label: "Visits", session: {"user_id" => "42"})
```

`Azu::Spark.render` signs the component id, type, props and session claims with `config.secret`, which Spark
reads from `SPARK_SECRET`. Without it, development and test use a random per-process secret, and production and
staging raise `Azu::Spark::ConfigurationError` the first time a token is signed or verified (not at boot:
`Spark.install` does not read the secret). Props are checked at compile time.

### Configuration

`Azu::CONFIG.spark` (`Azu::Spark.config`) exposes `path`, `assets_path`, `secret`, `token_ttl`,
`allowed_origins`, `max_message_size`, `compress_threshold`, `max_components`, `events_per_second`, `event_burst`,
`heartbeat_interval`, `idle_timeout`, `snapshot_ttl` and `max_snapshot_size`. Each is read from a `SPARK_*`
environment variable: see [Configuration options](../configuration/options.md#spark).

### Testing

`Azu::Spark::Testing` drives a component with a real session, without a WebSocket.

```crystal
require "spec"

class Counter < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"
  state count : Int32 = 0

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  def render
    h2 "#{label}: #{count}"
  end
end


describe Counter do
  it "counts" do
    Azu::Spark::Testing.mount(Counter, label: "Clicks") do |view|
      view.trigger("increment", by: 5)
      view.html.should contain("Clicks: 5")
      view.assigns[:count].should eq 5
    end
  end
end
```

See [Testing WebSockets](../../how-to/testing/test-websockets.md) for the connection level.

## See also

- [Channel Reference](channel.md)
- [Building live components](../../how-to/real-time/build-live-component.md)
- [Spark live views](../../explanation/spark-live-views.md)
