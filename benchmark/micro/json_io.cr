require "./harness"

# Isolates response serialization from request parsing and application logic.
# Each path writes and closes a fresh response backed by a reused null sink.
# Input parsing is excluded. This is allocation accounting, not HTTP traffic.
Log.setup(:none)
sink = HotPath::NullIO.new
request = HTTP::Request.new("GET", "/")
{13, 16_384}.each do |size|
  value = {message: "x" * size}
  buffered = HotPath.bytes_per_call do
    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(sink))
    context.response.content_type = "application/json"
    context.response << value.to_json
    context.response.close
  end
  direct = HotPath.bytes_per_call do
    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(sink))
    Azu::Response::Json.new(value).write_to(context)
    context.response.close
  end
  puts "payload=#{size} buffered_bytes/call=#{buffered.round(1)} direct_bytes/call=#{direct.round(1)}"
end
