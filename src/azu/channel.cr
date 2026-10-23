require "http/web_socket"

module Azu
  # A channel encapsulates a logical unit of work similar to an Endpoint.
  #
  # Channels manage WebSocket connections, handling multiple instances where a single client
  # may have multiple WebSocket connections open to the application.
  #
  # Every hook is optional; override only what you need. `broadcast` reaches every open
  # connection of the channel class and `join "room"` / `broadcast "room", message`
  # target a subset:
  #
  # ```
  # class ChatChannel < Azu::Channel
  #   ws "/chat"
  #
  #   def on_connect
  #     send({type: "welcome"})
  #   end
  #
  #   def on_message(message : String)
  #     broadcast message, except_me: true
  #   end
  # end
  # ```
  #
  # To set up a WebSocket route in your routing service:
  #
  # ```
  # ExampleApp.router do
  #   ws "/hi", ExampleApp::ExampleChannel
  # end
  # ```
  #
  # ## Pings and Pongs: The Heartbeat of WebSockets
  #
  # After the handshake, either the client or the server can send a ping to the other party.
  # Upon receiving a ping, the recipient must promptly send back a pong. This mechanism ensures
  # that the client remains connected.
  abstract class Channel
    include HTTP::Handler

    # Open connections by channel class name, and room members by "ClassName/room".
    @@connections = {} of String => Set(Channel)
    @@rooms = {} of String => Set(Channel)
    @@mutex = Mutex.new

    @joined = Set(String).new

    getter! socket : HTTP::WebSocket

    def initialize(@socket : HTTP::WebSocket)
    end

    # Registers a WebSocket route
    def self.ws(path : Router::Path)
      CONFIG.router.ws(path, self)
    end

    # Sends *message* to every open connection of this channel class. Callable from
    # anywhere, e.g. an endpoint: `ChatChannel.broadcast("Server restarting")`.
    # Returns the number of connections reached.
    def self.broadcast(message : String) : Int32
      deliver(connections_of(name), message, nil)
    end

    # Sends *message* to the connections of this class that joined *room*.
    def self.broadcast(room : String, message : String) : Int32
      deliver(members_of(name, room), message, nil)
    end

    # Number of open connections of this channel class.
    def self.connection_count : Int32
      @@mutex.synchronize { @@connections[name]?.try(&.size) || 0 }
    end

    # Invoked when a connection is established
    def on_connect
    end

    # Invoked when a text message is received
    def on_message(message : String)
    end

    # Invoked when a binary message is received
    def on_binary(binary : Bytes)
    end

    # Invoked when a ping frame is received
    def on_ping(message : String)
    end

    # Invoked when a pong frame is received
    def on_pong(message : String)
    end

    # Invoked when the connection is closed
    def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    end

    # Sends a text frame to this connection.
    def send(message : String) : Nil
      socket.send(message)
    end

    # Sends *data* as JSON to this connection.
    #
    # ```
    # send({type: "welcome", user: "ana"})
    # ```
    def send(data : Hash | NamedTuple | Array) : Nil
      socket.send(data.to_json)
    end

    # Sends *message* to every open connection of this channel class, including this one
    # unless *except_me* is true.
    #
    # ```
    # def on_message(message : String)
    #   broadcast message, except_me: true
    # end
    # ```
    def broadcast(message : String, except_me : Bool = false) : Int32
      self.class.deliver(self.class.connections_of(self.class.name), message, except_me ? self : nil)
    end

    # Sends *message* to the members of *room*.
    def broadcast(room : String, message : String, except_me : Bool = false) : Int32
      self.class.deliver(self.class.members_of(self.class.name, room), message, except_me ? self : nil)
    end

    # Joins *room*; the connection leaves every room when it closes.
    def join(room : String) : Nil
      @joined << room
      @@mutex.synchronize { (@@rooms["#{self.class.name}/#{room}"] ||= Set(Channel).new) << self }
    end

    # Leaves *room*.
    def leave(room : String) : Nil
      @joined.delete(room)
      @@mutex.synchronize { @@rooms["#{self.class.name}/#{room}"]?.try(&.delete(self)) }
    end

    # Handles the incoming WebSocket HTTP request
    def call(context : HTTP::Server::Context)
      register
      on_connect

      socket.on_message { |message| on_message(message) }
      socket.on_binary { |binary| on_binary(binary) }
      socket.on_ping { |message| on_ping(message) }
      socket.on_pong { |message| on_pong(message) }
      socket.on_close do |code, message|
        begin
          on_close(code, message)
        ensure
          unregister
        end
      end
    end

    # :nodoc:
    def self.connections_of(class_name : String) : Array(Channel)
      @@mutex.synchronize { @@connections[class_name]?.try(&.to_a) || [] of Channel }
    end

    # :nodoc:
    def self.members_of(class_name : String, room : String) : Array(Channel)
      @@mutex.synchronize { @@rooms["#{class_name}/#{room}"]?.try(&.to_a) || [] of Channel }
    end

    # :nodoc:
    def self.deliver(targets : Array(Channel), message : String, skip : Channel?) : Int32
      reached = 0
      targets.each do |target|
        next if target.same?(skip)
        begin
          target.socket.send(message)
          reached += 1
        rescue IO::Error
          target.unregister
        end
      end
      reached
    end

    # :nodoc:
    def register : Nil
      @@mutex.synchronize { (@@connections[self.class.name] ||= Set(Channel).new) << self }
    end

    # :nodoc:
    def unregister : Nil
      @@mutex.synchronize do
        @@connections[self.class.name]?.try(&.delete(self))
        @joined.each { |room| @@rooms["#{self.class.name}/#{room}"]?.try(&.delete(self)) }
      end
    end
  end
end
