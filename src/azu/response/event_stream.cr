require "./stream"

module Azu::Response
  # A `text/event-stream` (server-sent events) response. The block runs in its own fiber and sends
  # events to the `Source` it is given; the response writes each one as it arrives and flushes it, so
  # the client sees it at once.
  #
  # ```
  # def call : Azu::Response::EventStream
  #   Azu::Response::EventStream.new do |events|
  #     while events.open?
  #       events.send Azu::Response::EventStream::Event.new(Time.utc.to_s, event: "clock")
  #       events.sleep 1.second
  #     end
  #   end
  # end
  # ```
  #
  # The stream ends when
  #
  # * the block returns,
  # * a write fails because the client went away (`IO::Error`), noticed at the next event or heartbeat,
  # * the app begins shutting down (`Azu.shutting_down?`), so it never holds the drain.
  #
  # Then `Source#open?` turns false, so the block stops (`send` and `sleep` return false), and `on_close`
  # runs. A comment line (`: heartbeat`) is sent every `heartbeat` of silence, which keeps proxies from
  # closing an idle connection and is how a vanished client is noticed. The stream is not compressed,
  # buffered or cached.
  class EventStream
    include Streaming

    DEFAULT_HEARTBEAT = 15.seconds

    # The `Last-Event-ID` the client reconnected with (`?lastEventId=` for clients that cannot set the header).
    def self.last_event_id(request : HTTP::Request) : String?
      request.headers["Last-Event-ID"]?.presence || request.query_params["lastEventId"]?.presence
    end

    # One event of the stream. `data` may span lines; `id` and `event` may not.
    struct Event
      getter data : String
      getter event : String?
      getter id : String?
      getter retry : Time::Span?

      def initialize(@data : String = "", *, @event : String? = nil, @id : String? = nil, @retry : Time::Span? = nil)
        {@event, @id}.each { |field| raise ArgumentError.new("An event field cannot contain a line break") if field.try(&.matches?(/[\r\n]/)) }
        raise ArgumentError.new("An event id cannot contain NUL") if @id.try(&.includes?('\0'))
      end

      # An event whose data is the JSON of `value`.
      def self.json(value, *, event : String? = nil, id : String? = nil, retry : Time::Span? = nil) : Event
        new(value.to_json, event: event, id: id, retry: retry)
      end

      # The wire form: a field per line, one `data:` line per line of data, and a blank line to end the event.
      def to_s(io : IO) : Nil
        io << "id: " << id << '\n' if id
        io << "event: " << event << '\n' if event
        io << "retry: " << retry.try(&.total_milliseconds.to_i64) << '\n' if retry
        data.split(/\r\n|\r|\n/).each { |line| io << "data: " << line << '\n' }
        io << '\n'
      end
    end

    # What the block sends events to.
    class Source
      getter last_event_id : String?

      def initialize(@last_event_id : String?)
        @events = ::Channel(Event).new
        @closed = ::Channel(Nil).new
      end

      # :nodoc:
      getter events

      # False once the stream is over; the block stops when it is.
      def open? : Bool
        !@closed.closed?
      end

      # Sends an event; false, without sending, once the stream is over.
      def send(event : Event) : Bool
        select
        when @events.send(event)
          true
        when @closed.receive?
          false
        end
      end

      def send(data : String, *, event : String? = nil, id : String? = nil, retry : Time::Span? = nil) : Bool
        send(Event.new(data, event: event, id: id, retry: retry))
      end

      # Waits `span`, or less when the stream ends; false when it has.
      def sleep(span : Time::Span) : Bool
        select
        when @closed.receive?
        when timeout(span)
        end
        open?
      end

      # Sends the event the block builds for each value received from `channel`, until the channel
      # closes or the stream ends.
      def forward(channel : ::Channel(T), & : T -> Event) : Nil forall T
        loop do
          select
          when value = channel.receive?
            break if value.nil? || !send(yield value)
          when @closed.receive?
            break
          end
        end
      end

      # :nodoc:
      def close : Nil
        @closed.close
      end

      # :nodoc:
      def finish : Nil
        @events.close
      end
    end

    getter content_type : String = "text/event-stream"

    def initialize(@heartbeat : Time::Span = DEFAULT_HEARTBEAT, @retry : Time::Span? = nil, &@producer : Source ->)
    end

    def stream(context : HTTP::Server::Context) : Nil
      source = Source.new(EventStream.last_event_id(context.request))
      Azu.spawn_scoped("azu-event-stream") { produce(source) }
      begin
        pump(context.response, source)
      ensure
        source.close
      end
    end

    private def produce(source : Source) : Nil
      @producer.call(source)
    rescue ex
      Azu.current_config.log.error(exception: ex) { "Event stream producer failed" }
      source.send(Event.new("The stream failed", event: "error"))
    ensure
      source.finish
    end

    private def pump(output : IO, source : Source) : Nil
      shutdown = Azu.shutdown_signal
      emit(output, @retry ? "retry: #{@retry.try(&.total_milliseconds.to_i64)}\n\n" : ":\n\n")
      loop do
        select
        when event = source.events.receive?
          return unless event
          emit(output, event.to_s)
        when timeout(@heartbeat)
          emit(output, ": heartbeat\n\n")
        when shutdown.receive?
          return
        end
      end
    end

    private def emit(output : IO, text : String) : Nil
      output << text
      output.flush
    end
  end
end
