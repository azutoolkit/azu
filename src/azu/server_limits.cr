require "socket"

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

  # An accepted connection with the time limits of `ServerLimitsConfiguration`.
  #
  # A request is read in phases. `Headers`: from its first byte, or from the accept, until the blank line that ends the
  # headers, under one deadline (`header_timeout`), however the client slices its writes. `Body`: until the handler is
  # done with it, each read within `read_timeout` and the whole arriving no slower than `min_body_rate`. `Idle`: the
  # connection waits for the next request, `keep_alive_timeout`. The server never says when a request is over, so
  # the first read after the response was written is taken as the wait for the next one. An upgraded connection
  # (WebSocket) is `release`d by its handler and has no limit at all.
  class LimitedSocket < TCPSocket
    enum Phase
      Headers
      Body
      Idle
      Released
    end

    getter phase : Phase = Phase::Headers

    @deadline : Time::Instant
    @body_started : Time::Instant
    @received = 0_i64
    @line_length = 0
    @seen_line = false
    @seen_bytes = false
    @wrote = false
    @admitted = false

    def initialize(@limits : ServerLimitsConfiguration, @gate : ConnectionGate?, @inspect : Bool, *, handle, family, type, protocol, blocking)
      super(handle: handle, family: family, type: type, protocol: protocol, blocking: blocking)
      @deadline = Time.instant + @limits.header_timeout
      @body_started = Time.instant
      self.write_timeout = @limits.write_timeout
    end

    # Marks this socket as holding a place of the gate, given back when it is closed.
    def admitted! : Nil
      @admitted = true
    end

    # Takes every limit off (a WebSocket is meant to idle).
    def release : Nil
      @phase = Phase::Released
      self.read_timeout = nil
      self.write_timeout = nil
    end

    # Answers a connection the server has no room for, and closes it.
    def turn_away : Nil
      self.write_timeout = 1.second
      self << "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
      flush
    rescue IO::Error | Socket::Error
    ensure
      close rescue nil
    end

    private def unbuffered_read(slice : Bytes) : Int32
      return super if @phase.released?
      return read_with(@limits.read_timeout) { super } unless @inspect

      prepare_read
      count = super
      observe(slice[0, count]) if count > 0
      count
    rescue ex : IO::TimeoutError
      refuse_slow_request if @phase.headers? && @seen_bytes
      raise ex
    end

    private def read_with(timeout : Time::Span, &)
      self.read_timeout = timeout
      yield
    end

    private def unbuffered_write(slice : Bytes) : Nil
      @wrote = true
      super
    end

    private def unbuffered_close : Nil
      super
      @gate.try(&.leave) if @admitted
      @admitted = false
    end

    private def prepare_read : Nil
      now = Time.instant
      @phase = Phase::Idle if @phase.body? && @wrote
      case @phase
      when .headers?
        self.read_timeout = remaining(@deadline, now)
      when .body?
        deadline = body_deadline
        self.read_timeout = deadline ? {@limits.read_timeout, remaining(deadline, now)}.min : @limits.read_timeout
      when .idle?
        self.read_timeout = @limits.keep_alive_timeout
      end
    end

    # What is left until *deadline*; a deadline that has passed is a timeout now.
    private def remaining(deadline : Time::Instant, now : Time::Instant) : Time::Span
      left = deadline - now
      raise IO::TimeoutError.new("The client was too slow") if left <= Time::Span.zero
      left
    end

    private def body_deadline : Time::Instant?
      return if @limits.min_body_rate <= 0 # no total limit
      @body_started + @limits.read_timeout + (@received / @limits.min_body_rate).seconds
    end

    private def observe(bytes : Bytes) : Nil
      if @phase.idle?
        @phase = Phase::Headers
        @deadline = Time.instant + @limits.header_timeout
        @line_length = 0
        @seen_line = false
        @wrote = false
      end
      if @phase.body?
        @received += bytes.size
        return
      end
      @seen_bytes = true
      end_of_headers = scan_headers(bytes)
      return unless end_of_headers
      @phase = Phase::Body
      @body_started = Time.instant
      @received = (bytes.size - end_of_headers).to_i64
      @wrote = false
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

    private def refuse_slow_request : Nil
      self.write_timeout = 1.second
      unbuffered_write("HTTP/1.1 408 Request Timeout\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".to_slice)
    rescue IO::Error | Socket::Error
    end
  end

  # A `TCPServer` whose connections are `LimitedSocket`s, counted against `max_connections`.
  class LimitedTCPServer < TCPServer
    getter gate : ConnectionGate

    # *inspect* reads each request for its phases; off for TLS, where the bytes are not the request's.
    def initialize(host : String, port : Int32, @limits : ServerLimitsConfiguration, reuse_port : Bool = false, @nodelay : Bool = false, @inspect : Bool = true)
      @gate = ConnectionGate.new(@limits.max_connections)
      super(host, port, reuse_port: reuse_port)
    end

    def accept? : TCPSocket?
      loop do
        return if closed?
        pair = @fd_lock.read { system_accept } || return
        socket = LimitedSocket.new(@limits, @gate, @inspect, handle: pair[0], family: family, type: type, protocol: protocol, blocking: pair[1])
        socket.sync = sync?
        TCPNoDelay.apply(socket, @nodelay)
        if @gate.admit?
          socket.admitted!
          return socket
        end
        socket.turn_away
      end
    end
  end

  module ServerLimits
    # Takes the limits off *io* (and the TCP socket under a TLS one) once a handler has upgraded the connection.
    def self.release(io : IO) : Nil
      io.as?(LimitedSocket).try(&.release)
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
