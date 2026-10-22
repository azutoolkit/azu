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

    def render
      div class: "card" do
        h2 "#{label}: #{count}", id: "count"
        button "+1", **spark_click(:increment), id: "inc"
        button "+10", **spark_click(:increment, by: 10), id: "inc10"
        button "Reset", **spark_click(:reset), id: "reset"
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
          .card { border: 1px solid #ccc; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
          html[data-spark-status="connected"] #status::after { content: "connected"; color: green; }
          html:not([data-spark-status="connected"]) #status::after { content: "offline"; color: #b00; }
        </style>
        #{Azu::Spark.script_tag}
      </head>
      <body>
        <h1>Azu Spark <small id="status"></small></h1>
        #{Azu::Spark.render(Counter, label: "Clicks")}
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
  Azu::Spark.configure { |c| c.secret = ENV.fetch("SPARK_SECRET", "demo-only-secret-change-me") }
  Azu::Spark.install

  start [Azu::Handler::Rescuer.new, Azu::Handler::Logger.new]
end
