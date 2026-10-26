# Getting started with Azu Spark: a counter and a shared chat room, rendered by the server and
# kept live over one WebSocket per browser tab.
#
#   crystal run playground/spark_demo/app.cr        # then open http://localhost:3000
#   REDIS_URL=redis://localhost:6379/0 crystal run playground/spark_demo/app.cr
#
# With REDIS_URL set, chat messages travel through Redis, so several app processes share one
# room. Without it PubSub stays in memory.
require "../../src/azu"

module SparkDemo
  include Azu

  configure do |c|
    c.host = ENV.fetch("HOST", "127.0.0.1")
    c.port = ENV.fetch("PORT", "3000").to_i
    c.port_reuse = false
  end

  # A counter. `count` is persisted: it survives reconnects (and server restarts) inside a
  # signed snapshot the browser sends back when it rejoins.
  class Counter < Azu::Spark::Component
    mountable

    prop label : String = "Clicks"
    state count : Int32 = 0, persist: true

    event def increment(by : Int32 = 1) : Nil
      self.count += by
    end

    event def reset : Nil
      self.count = 0
    end

    # A slow backend: the browser test cuts the connection while this runs, then checks that the
    # event the client resent after the reconnect took effect exactly once.
    event def slow_increment : Nil
      sleep 400.milliseconds
      self.count += 1
    end

    def render
      div class: "card" do
        h2 "#{label}: #{count}", id: "count"
        button "+1", **spark_click(:increment), id: "inc"
        button "+10", **spark_click(:increment, by: 10), id: "inc10"
        button "Reset", **spark_click(:reset), id: "reset"
        button "+1 (slow)", **spark_click(:slow_increment), id: "slow"
      end
    end
  end

  # A report page of 150 rows: every "Next page" is a patch of about 18 KB of markup, which a client
  # that announced gzip receives as one compressed binary frame (see docs/reference/spark-client.md).
  class Ledger < Azu::Spark::Component
    mountable

    ROWS      = 150
    CUSTOMERS = ["Acme", "Globex", "Initech", "Umbrella", "Hooli", "Stark", "Wayne", "Wonka", "Soylent", "Tyrell"]
    STATUSES  = ["paid", "pending", "overdue", "refunded"]

    state page : Int32 = 1, persist: true

    event def turn : Nil
      self.page += 1
    end

    def render
      div class: "card" do
        h2 "Ledger page #{page}", id: "ledger-page"
        button "Next page", **spark_click(:turn), id: "ledger-turn"
        table class: "ledger" do
          tbody id: "ledger-rows" do
            ROWS.times do |row|
              number = page * ROWS + row
              tr do
                td "INV-#{(number * 7919 % 100_000).to_s.rjust(5, '0')}"
                td CUSTOMERS[number % CUSTOMERS.size]
                td STATUSES[(number * 31) % STATUSES.size]
                td "$#{(number * 104_729 % 90_000) / 100}.#{(number % 100).to_s.rjust(2, '0')}"
              end
            end
          end
        end
      end
    end
  end

  # A text field the server follows keystroke by keystroke. `edits` counts the events the server
  # applied: typing faster than it answers coalesces, so it ends up below the number of keystrokes
  # while `text` still ends up as the full text.
  class Echo < Azu::Spark::Component
    mountable

    state text : String = "", persist: true
    state edits : Int32 = 0, persist: true

    event def edit(value : String) : Nil
      sleep 120.milliseconds
      self.text = value
      self.edits += 1
    end

    def render
      div class: "card" do
        input **spark_change(:edit), type: "text", name: "echo", id: "echo", value: text, autocomplete: "off"
        span "Edits: #{edits}", id: "edits"
        span "Echo: #{text}", id: "echoed"
      end
    end
  end

  # A chat room. Every browser tab that mounts it subscribes to the "chat" topic; a message
  # sent from one tab is broadcast through PubSub and reaches `handle_info` of all of them.
  class ChatRoom < Azu::Spark::Component
    mountable

    TOPIC = "chat"

    state name : String = "guest"
    state lines : Array(String) = [] of String

    def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
      self.name = "guest-#{socket.id[-4..]}"
      socket.subscribe(TOPIC)
    end

    def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
      self.lines = (lines + [message.payload]).last(20)
    end

    event def say(text : String) : Nil
      text = text.strip
      return if text.empty?
      socket.broadcast(TOPIC, "#{name}: #{text[0, 200]}")
    end

    def render
      div class: "card" do
        h2 "Chat (you are #{name})"
        ul id: "lines" do
          lines.each { |line| li line }
        end
        form(**spark_submit(:say, disable_with: "Sending...")) do
          input type: "text", name: "text", autocomplete: "off", id: "text"
          button "Send", type: "submit", id: "send"
        end
      end
    end
  end

  struct HomeRequest
    include Azu::Request
  end

  struct Page
    include Azu::Response

    def render
      <<-HTML
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>Azu Spark demo</title>
        <style>
          body { font: 16px system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; }
          #lines { max-height: 6rem; overflow: auto; }
          .card { border: 1px solid #ccc; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
          html[data-spark-status="connected"] #status::after { content: "connected"; color: green; }
          html:not([data-spark-status="connected"]) #status::after { content: "offline"; color: #b00; }
        </style>
        #{Azu::Spark.script_tag}
      </head>
      <body>
        <h1>Azu Spark <small id="status"></small></h1>
        #{Azu::Spark.render(Counter, label: "Clicks")}
        #{Azu::Spark.render(Echo)}
        #{Azu::Spark.render(Ledger)}
        #{Azu::Spark.render(ChatRoom)}
      </body>
      </html>
      HTML
    end
  end

  struct HomeEndpoint
    include Azu::Endpoint(HomeRequest, Page)

    get "/"

    def call : Page
      content_type "text/html; charset=utf-8"
      Page.new
    end
  end

  if url = ENV["REDIS_URL"]?
    Azu::PubSub.backend = Azu::PubSub::Redis.new(url)
  end
  # Spark signs with SPARK_SECRET; without it a random per-process secret outside production, and no boot in production
  Azu::Spark.install

  start [Azu::Handler::Logger.new, Azu::Handler::Rescuer.new] of HTTP::Handler
end
