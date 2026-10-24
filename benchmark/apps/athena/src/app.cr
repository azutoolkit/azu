# Athena (athena-framework/framework) with its default listeners; controllers use annotation routing.
# Athena has no ORM and no WebSocket support, so the DB scenarios use crystal-sqlite3 and the
# websocket scenario is skipped for it (see benchmark/apps/manifest.json).
require "athena"
require "ecr"
require "db"
require "sqlite3"
require "../../common/bench"

module AthenaApp
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

  def self.render_template : String
    items = Bench::ITEMS
    ECR.render "#{__DIR__}/../../common/template.ecr"
  end
end

class BenchController < ATH::Controller
  @[ARTA::Get("/plaintext")]
  def plaintext : AHTTP::Response
    AHTTP::Response.new Bench::PLAINTEXT, headers: HTTP::Headers{"content-type" => "text/plain"}
  end

  # Returned as a value: Athena's view listener serializes it to JSON.
  @[ARTA::Get("/json")]
  def json : NamedTuple(message: String)
    Bench::JSON_MESSAGE
  end

  @[ARTA::Get("/template")]
  def template : AHTTP::Response
    AHTTP::Response.new AthenaApp.render_template, headers: HTTP::Headers{"content-type" => "text/html"}
  end

  {% for i in 0...100 %}
    @[ARTA::Get("/api/v1/resource{{ i }}/{id}")]
    def {{ "resource#{i}".id }}(id : String) : NamedTuple(route: String, id: String)
      {route: "resource{{ i }}", id: id}
    end
  {% end %}

  @[ARTA::Get("/db/item/{id}")]
  def item(id : String) : Bench::Row
    AthenaApp.find_item(id) || raise AHK::Exception::NotFound.new("Not Found")
  end

  @[ARTA::Get("/db/items")]
  def items : Array(Bench::Row)
    AthenaApp.list_items
  end
end

ATH.run(port: Bench::PORT, host: Bench::HOST)
