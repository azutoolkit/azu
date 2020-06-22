module Azu
  class LiveView < Channel
    def self.javascript_tag
      <<-HTML
        <script src="https://unpkg.com/preact@10.4.4/dist/preact.min.js"></script>
        <script src="https://unpkg.com/preact-html-converter@0.4.2/dist/preact-html-converter.browser.js"></script>
        <script src="https://cdn.jsdelivr.net/gh/jgaskins/live_view/js/live-view.min.js"></script>
      HTML
    end 

    getter? connected = false
    getter live_view_id = UUID.random.to_s

    # Start: Live View API 
    def on_event(name : String, data : String, socket : HTTP::WebSocket)
    end

    def render(io = IO::Memory.new)
    end

    def refresh(buffer = IO::Memory.new))
      render buffer
      json = {
        render: buffer.to_s,
        id: live_view_id,
      }.to_json
  
      socket.send json
    end
  
    def refresh(socket : HTTP::WebSocket, buffer = IO::Memory.new)
      yield
      refresh socket, buffer
    end

    def every(duration : Time::Span, &block)
      spawn do
        while connected?
          sleep duration
          block.call if connected?
        end
      end
    end

    # End: Live View API 

    def on_connect
      @connected = true
    end

    def on_close(code, message)
      @connected = false
      channel_names.each do |channel_name|
        CHANNELS[channel_name].unmount(socket)
        CHANNELS.delete channel_name
      end
    end

    def live_view(io, id = UUID.random.to_s)
      @live_view_id = id
      CHANNELS[live_view_id.to_s] = self
      io << %{<div data-live-view="#{live_view_id}"><div>}
      render io
      io << %{</div></div>}
    end

    def on_message(message : String)
      json = JSON.parse(message)

      if channel = json["subscribe"]?
        channel_name = channel.not_nil!.as_s
        channel_names << channel_name
        
      elsif event_name = json["event"]?
        channel_name = json["channel"].not_nil!.as_s
        data = json["data"].not_nil!.as_s
        on_event(event_name.as_s, data, socket)
      end
    end
  end
end