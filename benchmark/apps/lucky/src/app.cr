# Lucky, headless: actions, a page class for the template and Lucky's own handler chain
# (ErrorHandler, RouteHandler, RouteNotFoundHandler) without the LogHandler. Lucky's ORM (Avram) is
# PostgreSQL-only, so the DB scenarios use crystal-sqlite3. Lucky has no WebSocket support: that scenario is
# skipped for it (benchmark/apps/manifest.json).
require "lucky"
require "db"
require "sqlite3"
require "../../common/bench"

# Lucky logs every pipe of every request at INFO even without LogHandler: request logging is off for all apps
Log.setup(:warn)

Lucky::Server.configure do |settings|
  settings.secret_key_base = "0123456789012345678901234567890123456789012345678901234567890123"
  settings.host = Bench::HOST
  settings.port = Bench::PORT
  settings.gzip_enabled = false
end

Lucky::ErrorHandler.configure do |settings|
  settings.show_debug_output = false
end

Lucky::RouteHelper.configure do |settings|
  settings.base_uri = "http://#{Bench::HOST}:#{Bench::PORT}"
end

module LuckyApp
  DB = ::DB.open(Bench::DB_URI)

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

abstract class BenchAction < Lucky::Action
  disable_cookies
  accepted_formats [:html, :json, :plain_text], default: :json
end

class ItemsPage
  include Lucky::HTMLPage

  def render
    html_doctype
    html do
      head { title "Items" }
      body do
        h1 "Items"
        ul do
          Bench::ITEMS.each do |item|
            li "#{item.name} (#{item.price})", class: "item-#{item.id}"
          end
        end
      end
    end
  end
end

class Errors::Show < Lucky::ErrorAction
  default_format :plain_text
  disable_cookies
  dont_report [Lucky::RouteNotFoundError, Lucky::UnknownAcceptHeaderError]

  def render(error : Lucky::RouteNotFoundError | Lucky::UnknownAcceptHeaderError)
    plain_text "Not Found", status: 404
  end

  def default_render(error : Exception) : Lucky::Response
    plain_text "Internal Server Error", status: 500
  end

  def report(error : Exception) : Nil
  end
end

class Plaintext::Index < BenchAction
  get "/plaintext" do
    plain_text Bench::PLAINTEXT
  end
end

class Json::Index < BenchAction
  get "/json" do
    json Bench::JSON_MESSAGE
  end
end

class Template::Index < BenchAction
  get "/template" do
    html ItemsPage
  end
end

{% for i in 0...100 %}
  class {{ "Resource#{i}".id }}::Show < BenchAction
    get "/api/v1/resource{{ i }}/:id" do
      json({route: "resource{{ i }}", id: id})
    end
  end
{% end %}

class Db::Item::Show < BenchAction
  get "/db/item/:id" do
    if row = LuckyApp.find_item(id)
      json row
    else
      plain_text "Not Found", status: 404
    end
  end
end

class Db::Items::Index < BenchAction
  get "/db/items" do
    json LuckyApp.list_items
  end
end

class AppServer < Lucky::BaseAppServer
  def middleware : Array(HTTP::Handler)
    [
      Lucky::ErrorHandler.new(action: Errors::Show),
      Lucky::RouteHandler.new,
      Lucky::RouteNotFoundHandler.new,
    ] of HTTP::Handler
  end

  def listen
    server.listen(host, port, reuse_port: false)
  end
end

AppServer.new.listen
