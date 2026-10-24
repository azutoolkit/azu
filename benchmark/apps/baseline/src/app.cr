# Baseline: a plain HTTP::Server with a hand-written dispatch. It is the ceiling for what a Crystal
# HTTP stack does with no framework: no router, no middleware, no content negotiation.
require "http/server"
require "ecr"
require "db"
require "sqlite3"
require "../../common/bench"

module BaselineApp
  DB           = ::DB.open(Bench::DB_URI)
  SOCKETS      = [] of HTTP::WebSocket
  ROUTE_PREFIX = "/api/v1/resource"

  def self.render_template : String
    items = Bench::ITEMS
    ECR.render "#{__DIR__}/../../common/template.ecr"
  end

  def self.reply(context, body : String, type : String) : Nil
    context.response.content_type = type
    context.response.print body
  end

  def self.route(context, rest : String) : Bool
    slash = rest.index('/') || return false
    n = rest[0, slash].to_i? || return false
    return false unless 0 <= n < Bench::ROUTE_COUNT
    id = rest[slash + 1..]
    return false if id.empty? || id.includes?('/')
    reply context, Bench.route_body(n, id), "application/json"
    true
  end

  def self.handle(context : HTTP::Server::Context) : Nil
    request = context.request
    path = request.path
    return not_found(context) unless request.method == "GET"
    case path
    when "/plaintext" then reply context, Bench::PLAINTEXT, "text/plain"
    when "/json"      then reply context, Bench::JSON_MESSAGE.to_json, "application/json"
    when "/template"  then reply context, render_template, "text/html"
    when "/db/items"  then reply context, list_items.to_json, "application/json"
    else
      if path.starts_with?(ROUTE_PREFIX)
        return not_found(context) unless route(context, path[ROUTE_PREFIX.size..])
      elsif path.starts_with?("/db/item/")
        row = find_item(path[9..]) || return not_found(context)
        reply context, row.to_json, "application/json"
      else
        not_found(context)
      end
    end
  end

  def self.not_found(context) : Nil
    context.response.status_code = 404
    reply context, "Not Found", "text/plain"
  end

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

ws = HTTP::WebSocketHandler.new do |socket|
  BaselineApp::SOCKETS << socket
  socket.on_message do |message|
    BaselineApp::SOCKETS.each do |peer|
      peer.send(message)
    rescue IO::Error
    end
  end
  socket.on_close { BaselineApp::SOCKETS.delete(socket) }
end

Bench.quiet_logs

# The WebSocketHandler only claims upgrade requests; the block below answers everything else.
app = HTTP::Server.new([ws] of HTTP::Handler) { |context| BaselineApp.handle(context) }
app.bind_tcp Bench::HOST, Bench::PORT
puts "baseline listening on #{Bench::HOST}:#{Bench::PORT}"
app.listen
