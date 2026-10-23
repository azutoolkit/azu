# How to Build a Live Component

A live component keeps its state on the server. The browser sends events over a WebSocket, the server
renders again and sends back only the HTML that changed. This guide builds one step by step. For the
ideas behind it read [Components](../../explanation/concepts/components.md); for every option see the
[Component Reference](../../reference/api/component.md).

## A basic live component

Inherit from `Azu::Spark::Component`, declare state, declare the events the browser may trigger with
`event def`, and describe the HTML in `render`. `mountable` allows the component to be rendered from a page.

```crystal
class Counter < Azu::Spark::Component
  mountable

  prop label : String = "Clicks"
  state count : Int32 = 0

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  event def reset : Nil
    self.count = 0
  end

  def render
    div class: "counter" do
      h2 "#{label}: #{count}"
      button "+1", **spark_click(:increment)
      button "+10", **spark_click(:increment, by: 10)
      button "Reset", **spark_click(:reset)
    end
  end
end
```

- `prop` is a read-only input from the page; `state` is owned by the server and re-renders on change.
- `spark_click(:increment, by: 10)` makes the button send the `increment` event with `by = 10`. The
  browser can only trigger methods declared with `event def`, and the payload is converted to the
  declared parameter types.

## Serve it from a page

Install Spark once at boot, put the script tag in your layout and render the component where you want
it. The rendered markup contains a signed token that the browser uses to join the live connection.

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
    end
  end
end

Azu::Spark.configure { |c| c.secret = ENV.fetch("SPARK_SECRET", "development-only-secret") }
Azu::Spark.install

struct PageResponse
  include Azu::Response

  def render
    <<-HTML
    <!doctype html>
    <html>
      <body>
        #{Azu::Spark.render(Counter, label: "Visits")}
        #{Azu::Spark.script_tag}
      </body>
    </html>
    HTML
  end
end

struct PageEndpoint
  include Azu::Endpoint(Azu::Request, PageResponse)

  get "/"

  def call : PageResponse
    content_type "text/html"
    PageResponse.new
  end
end
```

`Azu::Spark.install` registers the WebSocket route (`/spark`) and the client script
(`/_spark/azu_spark.js`) on the router, so no CDN or inline script is involved. In production and
staging `SPARK_SECRET` (or `c.secret`) is required, because it signs the join tokens. Props given to
`Spark.render` are checked at compile time against the `prop` declarations.

Without JavaScript the page still shows the initial HTML; with it, every click updates the component.

## Props and session claims

Props travel inside the signed token, so they must be JSON serializable. For values that identify the
user, pass claims in `session:`; they are readable in `mount` as `socket.session`:

```crystal
class Greeting < Azu::Spark::Component
  mountable

  prop title : String
  state name : String = "guest"

  def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    self.name = socket.session["name"]? || "guest"
  end

  def render
    h1 "#{title}, #{name}"
  end
end

Azu::Spark.render(Greeting, title: "Welcome", session: {"name" => "Ada"})
```

`params` carries the query string of the page, so `params.fetch("page", Int32, 1)` reads `?page=2` with
a default.

## Handling form input

A form event receives the field values by name. A parameter typed as an `Azu::Request` receives the
whole payload, so the same contract that validates an endpoint validates the form:

```crystal
struct SignupRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name : String = "", @email : String = "")
  end

  validate name, presence: true, message: "Name is required"
  validate email, presence: true, message: "Email is required"
end

class Signup < Azu::Spark::Component
  mountable

  state signup : SignupRequest = SignupRequest.new
  state submitted : Bool = false

  event def submit(signup : SignupRequest) : Nil
    self.signup = signup
    self.submitted = true
  end

  private def problems(field : Symbol) : Array(String)
    submitted ? errors_on(signup, field) : [] of String
  end

  def render
    return div("Thanks, #{signup.name}!") if submitted && signup.valid?

    form(**spark_submit(:submit, disable_with: "Saving...")) do
      input type: "text", name: "name", value: signup.name
      problems(:name).each { |message| span message, class: "error" }
      input type: "email", name: "email", value: signup.email
      problems(:email).each { |message| span message, class: "error" }
      button "Sign up", type: "submit"
    end
  end
end
```

Use `spark_change(:event, debounce: 300)` on an input for live validation or search; `debounce` and
`throttle` limit how often the browser sends events.

## Lifecycle

```crystal
class Dashboard < Azu::Spark::Component
  mountable

  state visitors : Int32 = 0
  state log : Array(String) = [] of String

  def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    self.visitors = params.fetch("visitors", Int32, 0)
    socket.subscribe("dashboard")
    socket.every(30.seconds, "refresh")
  end

  def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
    if message.topic == "dashboard"
      self.log = (log + [message.payload]).last(5)
    else
      self.visitors += 1 # stand-in for reloading data
    end
  end

  def unmount(socket : Azu::Spark::Socket) : Nil
    # Subscriptions and timers are cancelled for you.
  end

  def render
    div do
      h2 "Visitors: #{visitors}"
      ul { log.each { |entry| li entry } }
    end
  end
end
```

`mount` runs on the HTTP render (`socket.connected?` is false, so `subscribe` and timers do nothing yet)
and again when the browser joins. `handle_info` receives PubSub broadcasts, timers (`every`,
`send_after`) and messages sent with `send_info`.

## Push updates from anywhere

Every `Dashboard` that is mounted somewhere receives this broadcast and re-renders:

```crystal
Azu::PubSub.broadcast("dashboard", "deploy finished")
```

See [Broadcast Messages](broadcast-messages.md) for the Redis backend that does the same across processes.

## Child components

Split a page into components that update independently. `live` embeds a child, identified among its
siblings by `key`:

```crystal
class Row < Azu::Spark::Component
  container "li"

  prop name : String
  state selected : Bool = false

  event def toggle : Nil
    self.selected = !selected
  end

  def render
    button "#{selected ? "[x]" : "[ ]"} #{name}", **spark_click(:toggle)
  end
end

class Table < Azu::Spark::Component
  mountable

  state names : Array(String) = ["Ada", "Grace", "Linus"]

  def render
    ul do
      names.each { |name| live Row, key: name, name: name }
    end
  end
end
```

Toggling a row re-renders that row only; the table and the other rows are not sent again. Give each
child a stable key (an id, not the index of a list that can reorder).

## Errors

An event that fails to convert (`by=many` for an `Int32`) is rejected before your handler runs and the
state is untouched. An exception raised inside a handler is logged and reported to the browser as an
`error` frame; outside development and test the frame carries only a generic text, never your message.
The component stays usable. Refuse a connection from `mount`:

```crystal
class AdminPanel < Azu::Spark::Component
  mountable

  def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    socket.reject!("forbidden") unless socket.session["role"]? == "admin"
  end

  def render
    h1 "Admin"
  end
end
```

## Test it

`Azu::Spark::Testing` drives a component with a real session and no WebSocket:

```crystal
require "spec"

class Counter < Azu::Spark::Component
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
  it "increments" do
    Azu::Spark::Testing.mount(Counter, label: "Hits") do |view|
      view.trigger("increment", by: 2)
      view.html.should contain("Hits: 2")
      view.assigns[:count].should eq 2
    end
  end
end
```

Testing over a real socket is covered in [Testing WebSockets](../testing/test-websockets.md).

## See also

- [Create a WebSocket channel](create-websocket-channel.md)
- [Broadcast Messages](broadcast-messages.md)
- [Spark live views](../../explanation/spark-live-views.md)
- [Component Reference](../../reference/api/component.md)
