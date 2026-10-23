# Azu getting-started demo: one file, no database, no Redis.
#
#   crystal run playground/app.cr          # then open http://localhost:4000
#
# What it shows, top to bottom:
#   1. Configuring the app
#   2. A tiny in-memory "database"
#   3. Endpoints: routing + validated params + JSON rendering
#   4. A live Spark component with state and events (a counter)
#   5. A live form with server-side validation (no JavaScript written)
#   6. A WebSocket channel with broadcast
#   7. The page that ties them together, and the server
require "../src/azu"

# 1. Configure -----------------------------------------------------------------
# `include Azu` gives the module `configure`, `routes`, `start`, ...
module Demo
  include Azu

  configure do |config|
    config.port = ENV.fetch("PORT", "4000").to_i
    config.host = ENV.fetch("HOST", "127.0.0.1")
    # One place to declare the middleware stack, in order. (This is also the default.)
    config.handlers do
      use Azu::Handler::RequestId.new
      use Azu::Handler::Rescuer.new # turns exceptions into JSON/HTML error responses
      use Azu::Handler::Logger.new
    end
  end
end

# 2. A tiny in-memory store ----------------------------------------------------
module Demo
  struct User
    include JSON::Serializable

    getter id : Int32
    getter email : String
    getter name : String

    def initialize(@id, @email, @name)
    end
  end

  module Users
    class EmailTaken < Exception
    end

    @@all = [] of User
    @@mutex = Mutex.new

    def self.all : Array(User)
      @@mutex.synchronize { @@all.dup }
    end

    def self.find?(id : Int32) : User?
      @@mutex.synchronize { @@all.find { |user| user.id == id } }
    end

    def self.create!(email : String, name : String) : User
      @@mutex.synchronize do
        raise EmailTaken.new(email) if @@all.any? { |user| user.email == email }
        User.new(@@all.size + 1, email, name).tap { |user| @@all << user }
      end
    end
  end
end

# 3. Endpoints -----------------------------------------------------------------
# One class per route. The verb line registers the route, `params` declares and
# validates input, `call` is the action.
module Demo
  # POST /api/users   {"email": "ana@example.com", "name": "Ana"}
  class CreateUser < Azu::Endpoint
    post "/api/users", as: :users

    # Typed, validated *before* `call` runs. Bad input never reaches your code: it is
    # answered with 422 and the list of invalid fields.
    params do
      param :email, String, required: true, format: :email
      param :name, String, required: true, min_length: 2, max_length: 40
    end

    def call
      user = Demo::Users.create!(params.email, params.name)
      render :created, user # 201 + JSON, no response class needed


    rescue Users::EmailTaken
      render :conflict, errors: {email: ["has already been taken"]}
    end
  end

  # GET /api/users?limit=2
  class ListUsers < Azu::Endpoint
    get "/api/users"

    params do
      param :limit, Int32, default: 50, min: 1, max: 100 # query-string params are typed too
    end

    def call
      render Demo::Users.all.first(params.limit) # `render x` is a 200 with JSON
    end
  end

  # GET /api/users/42
  class ShowUser < Azu::Endpoint
    get "/api/users/:id", as: :user # path params are declared like any other param

    params do
      param :id, Int32, required: true
    end

    def call
      if user = Demo::Users.find?(params.id)
        render user
      else
        render :not_found, errors: ["No user with id #{params.id}"]
      end
    end
  end

  # GET /health
  class Health < Azu::Endpoint
    get "/health"

    def call
      {status: "ok", users: Demo::Users.all.size} # returning a Hash/NamedTuple renders it as JSON
    end
  end
end

# 4. A live component ----------------------------------------------------------
# State lives on the server. Events from the browser call `on` handlers; changing a
# `state` re-renders the component and morphs the page in place.
module Demo
  class Counter
    include Azu::Component

    prop heading : String = "Clicks" # given once: Counter.mount(heading: "...")
    state count : Int32 = 0          # change it and the browser updates itself

    on :increment do
      self.count += 1
    end

    on :reset do
      self.count = 0
    end

    def content
      div do
        h2 { text "#{heading}: #{count}" }
        # `spark_click: :increment` sends the "increment" event to the handler above
        button(spark_click: :increment) { text "+1" }
        button(spark_click: :reset) { text "Reset" }
      end
    end
  end
end

# 5. A live form with validation -------------------------------------------------
# The payload of a form event is parsed into this contract, so the rules you wrote
# for your API are the rules of the live form too.
module Demo
  class SignupForm
    include Azu::Request

    getter email : String = ""
    getter name : String = ""

    validate email, match: /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, message: "must be an email address"
    validate name, size: 2..40, message: "must be between 2 and 40 characters"

    def initialize(@email = "", @name = "")
    end
  end

  class Signup
    include Azu::Component

    state errors : Hash(String, Array(String)) = Hash(String, Array(String)).new
    state welcome : String = ""

    # Runs as you type (see `spark_input` on the form). `form_errors` turns the
    # contract's errors into a Hash to store in a state.
    on :validate, SignupForm do |form|
      self.errors = form_errors(form)
    end

    on :save, SignupForm do |form|
      self.errors = form_errors(form)
      if errors.empty?
        user = Demo::Users.create!(form.email, form.name)
        self.welcome = "Welcome, #{user.name}!"
      end
    rescue Users::EmailTaken
      self.errors = {"email" => ["has already been taken"]}
    end

    def content
      div do
        if welcome.empty?
          # spark_submit: on submit send all fields as :save (no page reload)
          # spark_input:  on every keystroke send all fields as :validate, waiting 300 ms
          form(spark_submit: :save, spark_input: :validate, spark_debounce: 300, spark_reset: nil) do
            field "name", "Your name"
            field "email", "Email"
            button(type: "submit") { text "Sign up" }
          end
        else
          para { text welcome }
        end
      end
    end

    private def field(name : String, caption : String) : Nil
      div do
        label(for: name) { text caption }
        input(id: name, name: name, autocomplete: "off")
        errors[name]?.try &.each { |message| small(style: "color:#b00020") { text " #{caption} #{message}" } }
      end
    end
  end
end

# 6. A channel -----------------------------------------------------------------
# Only override the hooks you need. `broadcast` reaches every open connection.
module Demo
  class Chat < Azu::Channel
    ws "/chat"

    def on_connect
      broadcast "someone joined (#{self.class.connection_count} online)"
    end

    def on_message(message : String)
      broadcast message
    end
  end
end

# 7. The page and the server ---------------------------------------------------
module Demo
  # The Spark socket the components talk to.
  Azu::Spark.ws "/spark"

  class Home < Azu::Endpoint
    get "/"

    def call
      counter = Counter.mount(heading: "Clicks so far")
      signup = Signup.mount

      render html: <<-HTML
        <!doctype html>
        <meta charset="utf-8">
        <title>Azu demo</title>
        <body style="font-family: system-ui; max-width: 40rem; margin: 2rem auto">
          <h1>Azu demo</h1>

          <h3>Live counter</h3>
          #{counter.render}

          <h3>Live form</h3>
          #{signup.render}

          <h3>Chat</h3>
          <input id="message" placeholder="Say something" autocomplete="off">
          <ul id="log"></ul>

          <p>API: <a href="/api/users">/api/users</a> · <a href="/health">/health</a></p>

          #{Azu::Spark.javascript_tag}
          <script>
            const chat = new WebSocket(`ws://${location.host}/chat`);
            chat.onmessage = (e) => log.insertAdjacentHTML('beforeend', `<li>${e.data.replace(/</g, '&lt;')}</li>`);
            message.onkeydown = (e) => { if (e.key === 'Enter' && message.value) { chat.send(message.value); message.value = ''; } };
          </script>
        </body>
      HTML
    end
  end
end

# Start unless a spec/test loaded this file to drive the endpoints with Azu::Test::Client.
Demo.start unless ENV["AZU_DEMO_NO_SERVER"]?
