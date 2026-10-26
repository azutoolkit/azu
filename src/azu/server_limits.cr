require "socket"
require "openssl"

module Azu
  # Counts the connections a server serves, so that one over the limit is turned away.
  class ConnectionGate
    getter max : Int32

    def initialize(@max : Int32)
      @open = Atomic(Int32).new(0)
    end

    # Takes a place; false when all are taken. With no limit it always succeeds.
    def admit? : Bool
      return true if @max <= 0
      loop do
        current = @open.get
        return false if current >= @max
        return true if @open.compare_and_set(current, current + 1)[1]
      end
    end

    def leave : Nil
      @open.sub(1) if @max > 0
    end

    def open : Int32
      @open.get
    end
  end

  # The time rules of `ServerLimitsConfiguration` for one connection, as a state machine over what the client sends and
  # what the server writes. It reads the request, so it works on plain text: the socket itself for HTTP, the decrypted
  # stream for HTTPS.
  #
  # `Headers`: from the first byte of a request, or from the accept (a TLS handshake included), until the blank line
  # that ends the headers, under one deadline (`header_timeout`), however the client slices its writes. `Body`: until the
  # handler is done with it, each read within `read_timeout` and the whole arriving no slower than `min_body_rate`.
  # `Idle`: the connection waits for the next request, `keep_alive_timeout`. The server never says when a request is
  # over, so the first read after a final response was written is taken as the wait for the next one; an informational
  # `1xx` (`100 Continue`) is not a response. `Released`: an upgraded connection (WebSocket) has no limit at all.
  class RequestClock
    enum Phase
      Headers
      Body
      Idle
      Released
    end

    # The credit a fast start buys toward the body's deadline, in multiples of `read_timeout`.
    BODY_CREDIT_FACTOR = 10

    getter phase : Phase = Phase::Headers
    getter? seen_bytes : Bool = false

    @deadline : Time::Instant?

    def initialize(@limits : ServerLimitsConfiguration)
      @opened = Time.instant
      @deadline = @limits.header_timeout.try { |span| @opened + span }
      @body_started = @opened
      @received = 0_i64
      @line_length = 0
      @seen_line = false
      @wrote = false
    end

    # How long the next read may wait, nil for as long as it takes; raises `IO::TimeoutError` when a deadline has passed.
    def before_read : Time::Span?
      now = Time.instant
      @phase = Phase::Idle if @phase.body? && @wrote
      case @phase
      when .headers? then soonest(@deadline.try { |deadline| remaining(deadline, now) }, @limits.read_timeout)
      when .body?    then soonest(@limits.read_timeout, body_deadline.try { |deadline| remaining(deadline, now) })
      when .idle?    then @limits.keep_alive_timeout
      end
    end

    def after_read(bytes : Bytes) : Nil
      return if bytes.empty? || @phase.released?
      begin_request if @phase.idle?
      if @phase.body?
        @received += bytes.size
        return
      end
      @seen_bytes = true
      return unless end_of_headers = scan_headers(bytes)
      @phase = Phase::Body
      @body_started = Time.instant
      @received = (bytes.size - end_of_headers).to_i64
      @wrote = false
    end

    # A response, final or not, was written. Only a final one ends the request.
    def after_write(slice : Bytes) : Nil
      @wrote = true unless informational?(slice)
    end

    def release : Nil
      @phase = Phase::Released
    end

    private def begin_request : Nil
      @phase = Phase::Headers
      @deadline = @limits.header_timeout.try { |span| Time.instant + span }
      @line_length = 0
      @seen_line = false
      @wrote = false
    end

    # `HTTP/1.x 1xx ...`: the status line of an informational response.
    private def informational?(slice : Bytes) : Bool
      slice.size > 9 && slice[0, 7] == "HTTP/1.".to_slice && slice[8] == ' '.ord && slice[9] == '1'.ord
    end

    # What is left until *deadline*; a deadline that has passed is a timeout now.
    private def remaining(deadline : Time::Instant, now : Time::Instant) : Time::Span
      left = deadline - now
      raise IO::TimeoutError.new("The client was too slow") if left <= Time::Span.zero
      left
    end

    private def soonest(first : Time::Span?, second : Time::Span?) : Time::Span?
      return second unless first
      return first unless second
      Math.min(first, second)
    end

    # When the body has to be in by: `read_timeout` of grace and the time its bytes so far earn at `min_body_rate`,
    # with the earned part capped so a burst at the start cannot buy hours.
    # :nodoc:
    def body_deadline : Time::Instant?
      return if @limits.min_body_rate <= 0
      grace = @limits.read_timeout || return
      earned = {(@received / @limits.min_body_rate).seconds, grace * BODY_CREDIT_FACTOR}.min
      @body_started + grace + earned
    end

    # The index just past the blank line that ends the headers in *bytes*, if it does. Lines end in LF, with or without
    # a CR; blank lines before the request line are not the end.
    private def scan_headers(bytes : Bytes) : Int32?
      bytes.each_with_index do |byte, index|
        if byte == '\n'.ord
          return index + 1 if @line_length == 0 && @seen_line
          @seen_line = true if @line_length > 0
          @line_length = 0
        elsif byte != '\r'.ord
          @line_length += 1
        end
      end
      nil
    end
  end

  # An accepted TCP connection with the limits of `ServerLimitsConfiguration`. A plain one runs its `RequestClock` on
  # the bytes it reads; under TLS it is the transport of a `LimitedSSLSocket`, which runs the clock on the decrypted
  # stream, and only bounds the handshake itself.
  class LimitedSocket < TCPSocket
    getter clock : RequestClock

    def initialize(@limits : ServerLimitsConfiguration, @gate : ConnectionGate?, @tls : Bool, *, handle, family, type, protocol, blocking)
      super(handle: handle, family: family, type: type, protocol: protocol, blocking: blocking)
      @clock = RequestClock.new(@limits)
      @admitted = Atomic(Int32).new(0)
      @tls_ready = false
      self.write_timeout = @limits.write_timeout
    end

    # Marks this socket as holding a place of the gate, given back when it is closed.
    def admitted! : Nil
      @admitted.set(1)
    end

    # The TLS handshake is done: the layer above sets the read timeouts from now on.
    def tls_ready! : Nil
      @tls_ready = true
    end

    # Takes every limit off (a WebSocket is meant to idle).
    def release : Nil
      @clock.release
      self.read_timeout = nil
      self.write_timeout = nil
    end

    # Answers a connection the server has no room for, and closes it. On a TLS port there is no way to say 503 in
    # plain text that a client could read, so the connection is just closed.
    def turn_away : Nil
      unless @tls
        self.write_timeout = 1.second
        self << "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        flush
      end
    rescue IO::Error | Socket::Error
    ensure
      close rescue nil
    end

    private def unbuffered_read(slice : Bytes) : Int32
      return super if @tls && @tls_ready # the layer above set the timeout for this read

      self.read_timeout = @clock.before_read
      count = super
      @clock.after_read(slice[0, count]) unless @tls
      count
    rescue ex : IO::TimeoutError
      refuse_slow_request if !@tls && @clock.phase.headers? && @clock.seen_bytes?
      raise ex
    end

    private def unbuffered_write(slice : Bytes) : Nil
      @clock.after_write(slice) unless @tls
      super
    end

    private def unbuffered_close : Nil
      super
      @gate.try(&.leave) if @admitted.swap(0) == 1
    end

    private def refuse_slow_request : Nil
      self.write_timeout = 1.second
      unbuffered_write("HTTP/1.1 408 Request Timeout\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".to_slice)
    rescue IO::Error | Socket::Error
    end
  end

  # The TLS side of a `LimitedSocket`: the same rules, run on the decrypted request.
  class LimitedSSLSocket < OpenSSL::SSL::Socket::Server
    def initialize(@transport : LimitedSocket, context : OpenSSL::SSL::Context::Server, sync_close : Bool, accept : Bool)
      @clock = @transport.clock
      super(@transport, context, sync_close, accept)
    end

    def accept : Nil
      super
      @transport.tls_ready!
    end

    def release : Nil
      @transport.release
    end

    def unbuffered_read(slice : Bytes) : Int32
      @transport.read_timeout = @clock.before_read
      count = super
      @clock.after_read(slice[0, count])
      count
    end

    def unbuffered_write(slice : Bytes) : Nil
      @clock.after_write(slice)
      super
    end
  end

  # An `OpenSSL::SSL::Server` whose sockets are `LimitedSSLSocket`s.
  class LimitedSSLServer < OpenSSL::SSL::Server
    private def new_ssl_socket(io)
      LimitedSSLSocket.new(io.as(LimitedSocket), @context, @sync_close, @start_immediately)
    end
  end

  # A `TCPServer` whose connections are `LimitedSocket`s, counted against `max_connections`.
  class LimitedTCPServer < TCPServer
    getter gate : ConnectionGate

    ACCEPT_BACKOFF = 20.milliseconds
    @@accept_errors = LogBudget.new(1)

    # *tls*: the connections carry TLS, whose request is not what is read from the socket.
    def initialize(host : String, port : Int32, @limits : ServerLimitsConfiguration, reuse_port : Bool = false, @nodelay : Bool = false, @tls : Bool = false)
      @gate = ConnectionGate.new(@limits.max_connections)
      super(host, port, reuse_port: reuse_port)
    end

    def accept? : TCPSocket?
      loop do
        return if closed?
        pair = accept_pair || next
        socket = LimitedSocket.new(@limits, @gate, @tls, handle: pair[0], family: family, type: type, protocol: protocol, blocking: pair[1])
        socket.sync = sync?
        TCPNoDelay.apply(socket, @nodelay)
        if @gate.admit?
          socket.admitted!
          return socket
        end
        socket.turn_away
      end
    end

    # The next connection waiting. Out of file descriptors (`EMFILE`, `ENFILE`) is not a reason to spin: wait a moment,
    # say so once a second, and try again when a descriptor has been freed.
    private def accept_pair
      @fd_lock.read { system_accept }
    rescue ex : IO::Error
      raise ex unless ex.os_error.in?(Errno::EMFILE, Errno::ENFILE)
      write, _ = @@accept_errors.take
      ServerLimitsConfiguration::LOG.error { "Cannot accept connections: out of file descriptors; lower SERVER_MAX_CONNECTIONS or raise ulimit -n" } if write
      sleep ACCEPT_BACKOFF
      nil
    end
  end

  module ServerLimits
    # Takes the limits off *io* once a handler has upgraded the connection.
    def self.release(io : IO) : Nil
      case io
      when LimitedSocket    then io.release
      when LimitedSSLSocket then io.release
      end
    end

    # Binds *server* to a plain TCP listener whose connections are limited; returns its address.
    def self.bind_tcp(server : HTTP::Server, limits : ServerLimitsConfiguration, host : String, port : Int32, reuse_port : Bool, nodelay : Bool = false) : Socket::IPAddress
      tcp_server = LimitedTCPServer.new(host, port, limits, reuse_port, nodelay)
      begin
        server.bind(tcp_server)
      rescue ex
        tcp_server.close
        raise ex
      end
      tcp_server.local_address
    end
  end
end
