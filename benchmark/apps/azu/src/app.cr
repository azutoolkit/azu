# Azu 0.6 style (Azu::App as a value) with its default handler stack minus the request logger (RequestId, Rescuer, SecurityHeaders, Static).
#
# Build flags (see benchmark/apps/manifest.json):
#   -Dbench_minimal_handlers  only Rescuer, to separate the router/endpoint cost from the default middleware
#   -Dbench_raw_db            the DB scenarios use crystal-sqlite3 directly instead of CQL
require "../../../../src/azu"
require "sqlite3"
require "db"
require "cql"
require "../../common/bench"

module BenchApp
  struct NoRequest
    include Azu::Request
  end

  # A body that is already rendered: text, JSON or a rendered template.
  struct Raw
    include Azu::Response

    def initialize(@body : String)
    end

    def render
      @body
    end
  end

  struct ItemsPage
    include Azu::Response
    include Azu::Templates::Renderable

    def render
      items = Bench::ITEMS.map do |item|
        {"id" => Crinja::Value.new(item.id), "name" => Crinja::Value.new(item.name), "price" => Crinja::Value.new(item.price)}
      end
      view "template.jinja", {"items" => items}
    end
  end

  {% if flag?(:bench_raw_db) %}
    RAW_DB = ::DB.open(Bench::DB_URI)

    def self.find_item(id : String) : Bench::Row?
      key = id.to_i64? || return nil
      RAW_DB.query_one?("SELECT id, name, value FROM items WHERE id = ?", key, as: {Int64, String, Int64}).try { |r| Bench::Row.new(*r) }
    end

    def self.list_items : Array(Bench::Row)
      rows = [] of Bench::Row
      RAW_DB.query("SELECT id, name, value FROM items ORDER BY id LIMIT ?", Bench::DB_LIST_LIMIT) do |rs|
        rs.each { rows << Bench::Row.new(rs.read(Int64), rs.read(String), rs.read(Int64)) }
      end
      rows
    end
  {% else %}
    BenchDB = CQL::Schema.define(:bench, adapter: CQL::Adapter::SQLite, uri: Bench::DB_URI) do
      table :items do
        primary :id, Int64
        text :name
        bigint :value
      end
    end

    class Item
      include CQL::ActiveRecord::Model(Int64)
      db_context schema: BenchDB, table: :items

      property name : String
      property value : Int64

      def initialize(@name : String, @value : Int64)
      end

      def to_row : Bench::Row
        Bench::Row.new(id.not_nil!, name, value)
      end
    end

    def self.find_item(id : String) : Bench::Row?
      key = id.to_i64? || return nil
      Item.find?(key).try(&.to_row)
    end

    def self.list_items : Array(Bench::Row)
      Item.order(:id).limit(Bench::DB_LIST_LIMIT).all.map(&.to_row)
    end
  {% end %}

  struct PlaintextEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      content_type "text/plain"
      Raw.new(Bench::PLAINTEXT)
    end
  end

  struct JsonEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      content_type "application/json"
      Raw.new(Bench::JSON_MESSAGE.to_json)
    end
  end

  struct TemplateEndpoint
    include Azu::Endpoint(NoRequest, ItemsPage)

    def call : ItemsPage
      content_type "text/html"
      ItemsPage.new
    end
  end

  {% for i in 0...100 %}
    struct {{ "Resource#{i}Endpoint".id }}
      include Azu::Endpoint(NoRequest, Raw)

      def call : Raw
        content_type "application/json"
        Raw.new(Bench.route_body({{ i }}, params["id"]))
      end
    end
  {% end %}

  struct ItemEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      row = BenchApp.find_item(params["id"]) || raise Azu::Response::NotFound.new(context.request.path)
      content_type "application/json"
      Raw.new(row.to_json)
    end
  end

  struct ItemsEndpoint
    include Azu::Endpoint(NoRequest, Raw)

    def call : Raw
      content_type "application/json"
      Raw.new(BenchApp.list_items.to_json)
    end
  end

  # Every message a client sends goes to all clients, the sender included.
  class FanoutChannel < Azu::Channel
    def on_connect
      subscribe "bench"
    end

    def on_message(message : String)
      broadcast("bench", message)
    end

    def on_binary(binary : Bytes)
    end

    def on_ping(message : String)
    end

    def on_pong(message : String)
    end

    def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    end
  end
end

Bench.quiet_logs

app = Azu::App.new
app.config.host = Bench::HOST
app.config.port = Bench::PORT
app.config.websocket.tcp_nodelay = Bench.nodelay?
app.config.env = Azu::Environment::Production
app.config.templates.path = File.expand_path(File.join(__DIR__, "..", "..", "common"))

app.routes do
  get "/plaintext", BenchApp::PlaintextEndpoint
  get "/json", BenchApp::JsonEndpoint
  get "/template", BenchApp::TemplateEndpoint
  {% for i in 0...100 %}
    get "/api/v1/resource{{ i }}/:id", BenchApp::{{ "Resource#{i}Endpoint".id }}
  {% end %}
  get "/db/item/:id", BenchApp::ItemEndpoint
  get "/db/items", BenchApp::ItemsEndpoint
  ws "/ws", BenchApp::FanoutChannel
end

handlers = {% if flag?(:bench_minimal_handlers) %}
             [Azu::Handler::Rescuer.new] of HTTP::Handler
           {% else %}
             [
               Azu::Handler::RequestId.new,
               Azu::Handler::Rescuer.new,
               Azu::Handler::SecurityHeaders.new,
               Azu::Handler::Static.new(fallthrough: true, cache_max_age: app.config.assets.cache_max_age),
             ] of HTTP::Handler
           {% end %}

server = app.server(handlers)
server.bind_tcp app.config.host, app.config.port
Signal::TERM.trap { app.stop }
Signal::INT.trap { app.stop }
Azu.prepare
puts "azu listening on #{app.config.host}:#{app.config.port}"
server.listen
Azu.shutdown
