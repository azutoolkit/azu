require "random/secure"
require "./channel"
require "./router"
require "./spark/configuration"
require "./spark/connection"

module Azu
  # Spark keeps server rendered components in sync with the browser over a WebSocket, in the
  # spirit of Phoenix LiveView: state lives on the server, the browser sends events, the server
  # renders again and sends only the HTML of the components that changed.
  #
  # ```
  # # once, at boot
  # Azu::Spark.install
  #
  # # in a page
  # Azu::Spark.script_tag
  # Azu::Spark.render(CounterView, label: "Clicks", session: {"user_id" => "42"})
  # ```
  #
  # See `Azu::Spark::Component` for the component DSL and `docs/explanation/spark-live-views.md`
  # for the architecture and wire protocol.
  module Spark
    @@connections = Set(Connection).new
    @@mutex = Mutex.new

    def self.config : Configuration
      Azu.current_config.spark
    end

    def self.configure(& : Configuration ->) : Nil
      yield config
    end

    # Registers the WebSocket endpoint on *router*. Call once while booting.
    def self.install(router : Router = Azu.current_config.router) : Nil
      router.ws(config.path, Connection)
    end

    # Renders the mountable component *type* for an HTML page: the full initial markup plus a
    # signed token the browser uses to join the live connection. *session* claims are readable
    # in `mount` as `socket.session`; *params* arrive as the `params` argument of `mount`.
    # Props are checked against the component's `prop` declarations at compile time.
    def self.render(type : T.class, *, session : Hash(String, String) = {} of String => String,
                    params : Hash(String, String) = {} of String => String, **props) : String forall T
      {% raise "#{T} must declare `mountable` to be rendered from a page" unless T.constant("SPARK_OPTIONS")[:mountable] %}

      component = T.new(**props)
      id = "spark-#{Random::Secure.hex(8)}"
      claims = {id: id, view: T.name, props: JSON.parse(component.__spark_props_json), session: session}
      token = Token.sign("join", JSON.parse(claims.to_json), config.token_ttl)
      Session.new(ConnectionInfo.detached, false) { |_| }.render_page(
        component, id, session, Params.from_strings(params), "data-spark-root": nil, "data-spark-token": token)
    end

    # Closes every connection with a "service restart" so clients reconnect to the next process.
    def self.shutdown : Nil
      connections = @@mutex.synchronize { @@connections.to_a }
      connections.each(&.close(HTTP::WebSocket::CloseCode::ServiceRestart, "server stopping"))
    end

    # Number of open Spark connections.
    def self.connection_count : Int32
      @@mutex.synchronize { @@connections.size }
    end

    # :nodoc:
    def self.track(connection : Connection) : Nil
      @@mutex.synchronize { @@connections << connection }
    end

    # :nodoc:
    def self.untrack(connection : Connection) : Nil
      @@mutex.synchronize { @@connections.delete(connection) }
    end
  end
end
