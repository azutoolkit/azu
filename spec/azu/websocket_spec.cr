require "../spec_helper"

describe Azu::Channel do
  pending "sends socket message" do
    result = nil
    socket = HTTP::WebSocket.new URI.parse("ws://localhost:4000/hi")
    socket.on_message { |msg| result = msg }

    spawn socket.run
    socket.send "Marco!"
    sleep 40.milliseconds

    result.should eq "Polo!"
  end

  pending "removes subscriber on disconnect" do
    result = nil
    socket = HTTP::WebSocket.new URI.parse("ws://localhost:4000/hi")
    HTTP::WebSocket.new URI.parse("ws://localhost:4000/hi")
    socket.on_message { |msg| result = msg }

    spawn socket.run
    sleep 40.milliseconds

    result.should eq "2"
  end
end
