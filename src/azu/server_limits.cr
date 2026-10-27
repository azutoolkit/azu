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

  # Where the requests of a connection begin and end in the bytes the client sends, as far as the bytes tell: the end of
  # each request's headers, and the end of its body when it has a `Content-Length` (or none, which is a body of 0). A
  # body of unknown length (`Transfer-Encoding`) ends where the server answers it: `restart` scans for the next request.
  class RequestStream
    # The bytes of a header line kept to recognise it: `Content-Length` and `Transfer-Encoding` with their values.
    LINE_LIMIT = 64

    # The requests whose headers have ended.
    getter parsed : Int32 = 0
    # Bytes of the next request's headers have arrived (its blank lines included).
    getter? partial : Bool = false

    @body_left : Int64? = 0_i64

    def initialize
      @line = Bytes.new(LINE_LIMIT)
      @line_length = 0
      @seen_line = false
      @in_body = false
      @content_length = nil.as(Int64?)
      @unknown_length = false
    end

    # In the body of a request whose length the headers did not give.
    def unknown_body? : Bool
      @in_body && @body_left.nil?
    end

    def feed(bytes : Bytes) : Nil
      index = 0
      while index < bytes.size
        if @in_body
          left = @body_left || return
          taken = Math.min(left, (bytes.size - index).to_i64)
          index += taken
          @body_left = left - taken
          @in_body = false if left == taken
        else
          index = scan(bytes, index)
        end
      end
    end

    # The answer to a body of unknown length was written: what comes next is a new request.
    def restart : Nil
      @in_body = false
      start_headers
    end

    # Scans header bytes from *index*; returns the index just past the blank line that ends them, or the end of *bytes*.
    # Lines end in LF, with or without a CR; blank lines before the request line are not the end.
    private def scan(bytes : Bytes, index : Int32) : Int32
      @partial = true
      while index < bytes.size
        byte = bytes[index]
        index += 1
        if byte == '\n'.ord
          if @line_length == 0 && @seen_line
            end_headers
            return index
          end
          end_line if @line_length > 0
        elsif byte != '\r'.ord
          @line[@line_length] = byte if @line_length < LINE_LIMIT
          @line_length += 1
        end
      end
      index
    end

    # A header line is a body length, or not; the first line is the request line.
    private def end_line : Nil
      read_length if @seen_line
      @seen_line = true
      @line_length = 0
    end

    private def read_length : Nil
      line = String.new(@line[0, Math.min(@line_length, LINE_LIMIT)])
      name, colon, value = line.partition(':')
      return if colon.empty?
      case name.strip.downcase
      when "transfer-encoding" then @unknown_length = true
      when "content-length"
        length = @line_length <= LINE_LIMIT ? value.strip.to_i64?(whitespace: false) : nil
        @unknown_length = true if length.nil? || length < 0 || (@content_length && @content_length != length)
        @content_length = length
      end
    end

    private def end_headers : Nil
      @parsed += 1
      @body_left = @unknown_length ? nil : (@content_length || 0_i64)
      @in_body = @body_left != 0
      start_headers
    end

    private def start_headers : Nil
      @partial = false
      @line_length = 0
      @seen_line = false
      @content_length = nil
      @unknown_length = false
    end
  end

  # The time rules of `ServerLimitsConfiguration` for one connection, as a state machine over what the client sends and
  # what the server writes. It reads the request, so it works on plain text: the socket itself for HTTP, the decrypted
  # stream for HTTPS.
  #
  # `Headers`: from the first byte of a request, or from the accept (a TLS handshake included), until the blank line
  # that ends the headers, under one deadline (`header_timeout`), however the client slices its writes. `Body`: until the
  # handler is done with it, each read within `read_timeout`, and the time the server waits for the body paid for at
  # `min_body_rate` (a credit of at most `read_timeout`, so a body that keeps that pace is never cut, however long it
  # is, and time the server spends not reading is not the client's). `Idle`: the connection waits for the next request,
  # `keep_alive_timeout`. The server never says when a request is over, so the first read after a final response was
  # written is taken as the end of the request; an informational `1xx` (`100 Continue`) is not a response. Where the
  # next request begins is known from the bytes (`RequestStream`), so a request the client sent along with the previous
  # one is timed from the end of that one's response, as headers or, once they are complete, as a body.
  # `Released`: an upgraded connection (WebSocket) has no limit at all.
  class RequestClock
    enum Phase
      Headers
      Body
      Idle
      Released
    end

    getter phase : Phase = Phase::Headers

    @deadline : Time::Instant?
    @waiting_since : Time::Instant?

    def initialize(@limits : ServerLimitsConfiguration)
      @deadline = @limits.header_timeout.try { |span| Time.instant + span }
      @stream = RequestStream.new
      @answered = 0
      @wrote = false
      @credit = Time::Span.zero
    end

    # How long the next read may wait, nil for as long as it takes; raises `ServerLimits::ClientTooSlow` when a deadline
    # has passed.
    def before_read : Time::Span?
      next_request if @wrote && @phase.body?
      case @phase
      when .headers? then soonest(@deadline.try { |deadline| remaining(deadline) }, @limits.read_timeout)
      when .body?
        @waiting_since = Time.instant
        soonest(@limits.read_timeout, body_credit)
      when .idle? then @limits.keep_alive_timeout
      end
    end

    def after_read(bytes : Bytes) : Nil
      return if @phase.released?
      pay_for_wait(bytes.size)
      return if bytes.empty?
      @stream.feed(bytes)
      if @stream.parsed > @answered
        start_body unless @phase.body?
      elsif @phase.idle? && @stream.partial?
        start_headers
      end
    end

    # A response, final or not, was written. Only a final one ends the request.
    def after_write(slice : Bytes) : Nil
      @wrote = true unless informational?(slice)
    end

    def release : Nil
      @phase = Phase::Released
    end

    # The bytes of a request's headers have come and the headers are late: the client can be told `408` before the
    # connection is closed, as no handler is answering it.
    def refusable? : Bool
      @phase.headers? && @stream.partial?
    end

    # The request the server worked on was answered: the next one may have been sent already, in part or whole.
    private def next_request : Nil
      @answered += 1
      @wrote = false
      @stream.restart if @stream.unknown_body?
      if @stream.parsed > @answered
        start_body
      elsif @stream.partial?
        start_headers
      else
        @phase = Phase::Idle
      end
    end

    private def start_headers : Nil
      @phase = Phase::Headers
      @deadline = @limits.header_timeout.try { |span| Time.instant + span }
    end

    private def start_body : Nil
      @phase = Phase::Body
      @credit = @limits.read_timeout || Time::Span.zero
      @waiting_since = nil
    end

    # The time the server waited for these bytes comes off the credit, and the bytes earn time at `min_body_rate`.
    private def pay_for_wait(size : Int32) : Nil
      since = @waiting_since || return
      @waiting_since = nil
      return unless @phase.body? && @limits.min_body_rate > 0
      cap = @limits.read_timeout || return
      earned = (size / @limits.min_body_rate).seconds
      @credit = {@credit - (Time.instant - since) + earned, cap}.min
    end

    private def body_credit : Time::Span?
      return if @limits.min_body_rate <= 0 || @limits.read_timeout.nil?
      raise ServerLimits::ClientTooSlow.new if @credit <= Time::Span.zero
      @credit
    end

    # `HTTP/1.x 1xx ...`: the status line of an informational response.
    private def informational?(slice : Bytes) : Bool
      slice.size > 9 && slice[0, 7] == "HTTP/1.".to_slice && slice[8] == ' '.ord && slice[9] == '1'.ord
    end

    # What is left until *deadline*; a deadline that has passed is a timeout now.
    private def remaining(deadline : Time::Instant) : Time::Span
      left = deadline - Time.instant
      raise ServerLimits::ClientTooSlow.new if left <= Time::Span.zero
      left
    end

    private def soonest(first : Time::Span?, second : Time::Span?) : Time::Span?
      return second unless first
      return first unless second
      Math.min(first, second)
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
      refuse_slow_request if !@tls && @clock.refusable?
      raise ServerLimits.client_too_slow(ex)
    end

    private def unbuffered_write(slice : Bytes) : Nil
      @clock.after_write(slice) unless @tls
      super
    rescue ex : IO::TimeoutError
      raise ServerLimits.client_too_slow(ex)
    end

    private def unbuffered_close : Nil
      super
    ensure
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
    # The client did not send the request, or take the response, in time (see `ServerLimitsConfiguration`): what the
    # reads and writes of a limited connection raise, and what `Handler::Rescuer` answers `408`. Any other
    # `IO::TimeoutError` (an upstream HTTP client, Redis, a database) is the server's own failure.
    class ClientTooSlow < IO::TimeoutError
      def initialize(message : String = "The client was too slow", cause : Exception? = nil)
        super(message, cause)
      end
    end

    # *ex* as a `ClientTooSlow`: a timeout of a limited connection's own read or write is the client's.
    def self.client_too_slow(ex : IO::TimeoutError) : ClientTooSlow
      ex.as?(ClientTooSlow) || ClientTooSlow.new(ex.message || "The client was too slow", ex)
    end

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
