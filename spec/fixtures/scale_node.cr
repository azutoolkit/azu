# One node of the scale-out spec (spec/azu/scale_out_spec.cr): a tiny app that shares PubSub and Presence
# through Redis with the other nodes. Configured by the environment: NODE, PORT, REDIS_URL, PREFIX, TTL_MS.
require "../../src/azu"

node = ENV["NODE"]
redis_url = ENV["REDIS_URL"]
prefix = ENV["PREFIX"]

Azu::PubSub.backend = Azu::PubSub::Redis.new(redis_url, "#{prefix}bus:")
Azu::Presence.default = Azu::Presence::Tracker.new(
  Azu::Presence::Store::Redis.new(redis_url, "#{prefix}presence:"),
  node: node, ttl: ENV["TTL_MS"].to_i.milliseconds)

class ChatChannel < Azu::Channel
  include Azu::Presence::Tracked

  def on_connect
    user = params["user"]
    subscribe("room")
    presence_updates("room")
    track_presence("room", user, {"node" => ENV["NODE"]})
  end

  def on_message(message : String)
    broadcast("room", "msg:#{params["user"]}@#{ENV["NODE"]}:#{message}")
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

server = HTTP::Server.new([Azu::Channel::Upgrader.new(ChatChannel)]) do |context|
  case context.request.path
  when "/presence"
    context.response.content_type = "application/json"
    context.response.print Azu::Presence.list("room").transform_values { |metas| metas.map(&.node) }.to_json
  when "/health"
    context.response.print "ok"
  else
    context.response.respond_with_status(:not_found)
  end
end
server.bind_tcp("127.0.0.1", ENV["PORT"].to_i)
server.listen
