require "../channel"
require "random/secure"
require "./params"
require "./protocol"
require "./rate_limiter"
require "./session"

module Azu
  module Spark
    # The WebSocket endpoint of Spark (mounted by `Azu::Spark.install`). It owns the transport
    # concerns of ONE client: frame parsing, rate limiting, heartbeats and idle detection, and
    # the single fiber that feeds everything the client sends and everything PubSub or timers
    # deliver into its `Session`, one job at a time.
    class Connection < Azu::Channel
      private record Frame, text : String

      private alias Job = Frame | Info

      INBOX_CAPACITY      = 256
      MAX_RATE_VIOLATIONS =   5

      def self.max_message_size : Int32
        Spark.config.max_message_size
      end

      def self.allowed_origins : Array(String)
        super + Spark.config.allowed_origins
      end

      getter id : String

      def initialize(socket : HTTP::WebSocket)
        super
        @id = Random::Secure.hex(8)
        @config = Spark.config
        @inbox = ::Channel(Job).new(INBOX_CAPACITY)
        @finished = ::Channel(Nil).new
        @limiter = RateLimiter.new(@config.events_per_second, @config.event_burst)
        @violations = 0
        @sequence = 0_i64
        @ack = nil.as(Int64?)
        @started = Time.instant
        @last_seen = Atomic(Int64).new(0)
        @session = nil.as(Session?)
      end

      def on_connect
        @session = Session.new(ConnectionInfo.new(id, context.request.remote_address.try(&.to_s), context.request.headers), true, @config) do |info|
          enqueue(info)
        end
        Spark.track(self)
        Azu.spawn_scoped("azu-spark-connection") { process }
        Azu.spawn_scoped("azu-spark-watchdog") { watch }
        transmit(Protocol.hello(@config.heartbeat_interval, @config.max_message_size))
      end

      def on_message(message : String)
        touch
        return enqueue(Frame.new(message)) if @limiter.allow?

        id, eid = numbered(message)
        transmit(Protocol.error(id, "rate_limited", detail("rate_limited", "too many events"), ack: eid))
        close(HTTP::WebSocket::CloseCode::PolicyViolation, "rate limited") if (@violations += 1) >= MAX_RATE_VIOLATIONS
      end

      # The request id and event number a client puts at the end of an event frame (the browser
      # client does), read without parsing the frame: a flooding client must not make us do more work.
      # Lets the client end the refused event instead of waiting for an answer that never comes.
      private def numbered(message : String) : {Int64?, Int64?}
        if match = message[Math.max(message.size - 80, 0)..].match(/"id":(\d+),"eid":(\d+)(?:,"gen":"[^"]*")?\}\z/)
          {match[1].to_i64?, match[2].to_i64?}
        else
          {nil, nil}
        end
      end

      def on_binary(binary : Bytes)
        close(HTTP::WebSocket::CloseCode::UnsupportedData, "text frames only")
      end

      def on_ping(message : String)
        touch
      end

      def on_pong(message : String)
        touch
      end

      def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
        @inbox.close unless @inbox.closed?
      end

      # Processing loop. `receive?` returns nil once the inbox is closed and drained, which ends
      # the loop (a plain `receive` would raise on a closed channel).
      private def process : Nil
        while job = @inbox.receive?
          handle(job)
        end
      ensure
        @finished.close
        @session.try(&.close)
        Spark.untrack(self)
      end

      private def watch : Nil
        loop do
          select
          when @finished.receive?
            break
          when timeout({@config.idle_timeout / 2, 10.milliseconds}.max)
            close(HTTP::WebSocket::CloseCode::GoingAway, "idle") if idle?
          end
        end
      end

      private def enqueue(job : Job) : Nil
        select
        when @inbox.send(job)
        else
          close(HTTP::WebSocket::CloseCode::TryAgainLater, "overloaded")
        end
      rescue ::Channel::ClosedError
        # The connection is closing; whatever arrives now is moot.
      end

      private def handle(job : Job) : Nil
        case job
        in Frame then handle_frame(job.text)
        in Info  then guard(nil) { publish(session.info(job.target, job.message)) }
        end
      end

      private def handle_frame(text : String) : Nil
        guard(nil) do
          inbound = parse(text)
          @ack = inbound.eid.try { |eid| eid if eid > 0 } if inbound.type == "event"
          guard(inbound.id) { dispatch(inbound) }
        end
      ensure
        @ack = nil
      end

      private def parse(text : String) : Protocol::Inbound
        inbound = Protocol::Inbound.from_json(text)
        raise BadRequest.new("unsupported protocol version #{inbound.v}") unless inbound.v == Protocol::VERSION
        inbound
      rescue JSON::ParseException | JSON::SerializableError
        raise BadRequest.new("malformed frame")
      end

      private def dispatch(inbound : Protocol::Inbound) : Nil
        case inbound.type
        when "join"
          token = inbound.token || raise BadRequest.new("missing token")
          params = Params.from_strings(inbound.params || {} of String => String)
          joined = session.join(token, inbound.snapshot, params)
          publish(joined.update)
          transmit(Protocol.reply(inbound.id, gen: joined.generation))
        when "event"
          deliver(inbound)
        when "heartbeat"
          transmit(Protocol.heartbeat(inbound.id))
        when "leave"
          session.leave(inbound.target || raise BadRequest.new("missing target"))
        else
          raise BadRequest.new("unknown message type")
        end
      end

      # Applies a numbered event once. Every frame that answers it carries its number (`ack`), also
      # the error of an event that failed or was stale: the client is done with it either way.
      private def deliver(inbound : Protocol::Inbound) : Nil
        target = inbound.target || raise BadRequest.new("missing target")
        name = inbound.event || raise BadRequest.new("missing event")
        eid = inbound.eid
        raise BadRequest.new("event numbers start at 1") if eid && eid < 1
        if session.accept(target, eid, inbound.gen)
          publish(session.event(target, name, Params.new(inbound.payload || {} of String => JSON::Any)))
          transmit(Protocol.reply(inbound.id, target, ack: eid))
        else
          transmit(Protocol.reply(inbound.id, target, ack: eid, dup: true))
        end
      end

      # Runs the block, turning failures into error frames. Only `Spark::Error`s are the
      # client's business; anything else is logged and reported as an opaque internal error.
      private def guard(id : Int64?, &) : Nil
        yield
      rescue ex : Error
        report(id, ex)
      rescue ex
        Log.for("Azu::Spark").error(exception: ex) { "Unhandled error in connection #{self.id}" }
        report(id, Error.new(ex.message))
      end

      private def report(id : Int64?, error : Error) : Nil
        transmit(Protocol.error(id, error.code, detail(error.code, error.message), ack: @ack))
      end

      # Development and test see the real message; everywhere else only a generic text per code.
      private def detail(code : String, message : String?) : String
        Azu.current_config.env.in?(Azu::Environment::Development, Azu::Environment::Test) ? (message || code) : code.tr("_", " ")
      end

      private def publish(update : Update) : Nil
        unless update.patches.empty? && update.pushes.empty? && update.snapshots.empty?
          transmit(Protocol.diff(@sequence += 1, update, @ack))
        end
        update.redirect.try { |redirect| transmit(Protocol.redirect(redirect)) }
      end

      private def transmit(frame : String) : Nil
        send(frame)
      rescue IO::Error
        # The peer disconnected; the close callback ends the loop.
      end

      private def session : Session
        @session || raise Error.new("connection is not ready")
      end

      private def touch : Nil
        @last_seen.set(now_ms)
      end

      private def idle? : Bool
        now_ms - @last_seen.get > @config.idle_timeout.total_milliseconds
      end

      private def now_ms : Int64
        (Time.instant - @started).total_milliseconds.to_i64
      end
    end
  end
end
