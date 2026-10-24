# Kemal with its default handler stack (init, static file, exception, route) and request logging switched off.
require "kemal"
require "db"
require "sqlite3"
require "../../common/bench"
require "../../common/ws_nodelay"

module KemalApp
  DB      = ::DB.open(Bench::DB_URI)
  SOCKETS = [] of HTTP::WebSocket

  def self.find_item(id : String) : Bench::Row?
    key = id.to_i64? || return nil
    DB.query_one?("SELECT id, name, value FROM items WHERE id = ?", key, as: {Int64, String, Int64}).try { |r| Bench::Row.new(*r) }
  end

  def self.list_items : Array(Bench::Row)
    rows = [] of Bench::Row
    DB.query("SELECT id, name, value FROM items ORDER BY id LIMIT ?", Bench::DB_LIST_LIMIT) do |rs|
      rs.each { rows << Bench::Row.new(rs.read(Int64), rs.read(String), rs.read(Int64)) }
    end
    rows
  end
end

get "/plaintext" do |env|
  env.response.content_type = "text/plain"
  Bench::PLAINTEXT
end

get "/json" do |env|
  env.response.content_type = "application/json"
  Bench::JSON_MESSAGE.to_json
end

get "/template" do |env|
  env.response.content_type = "text/html"
  items = Bench::ITEMS
  render "#{__DIR__}/../../common/template.ecr"
end

{% for i in 0...100 %}
  get "/api/v1/resource{{ i }}/:id" do |env|
    env.response.content_type = "application/json"
    Bench.route_body({{ i }}, env.params.url["id"])
  end
{% end %}

get "/db/item/:id" do |env|
  row = KemalApp.find_item(env.params.url["id"])
  halt env, status_code: 404, response: "Not Found" unless row
  env.response.content_type = "application/json"
  row.to_json
end

get "/db/items" do |env|
  env.response.content_type = "application/json"
  KemalApp.list_items.to_json
end

ws "/ws" do |socket|
  KemalApp::SOCKETS << socket
  socket.on_message do |message|
    KemalApp::SOCKETS.each do |peer|
      peer.send(message)
    rescue IO::Error
    end
  end
  socket.on_close { KemalApp::SOCKETS.delete(socket) }
end

Kemal.config.logging = false
Kemal.config.powered_by_header = false
Kemal.config.env = "production"
Kemal.config.host_binding = Bench::HOST
Bench.quiet_logs
Kemal.run(Bench::PORT)
