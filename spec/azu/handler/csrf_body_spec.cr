require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

# Counts the bytes taken from the body it wraps, to show how much of it a handler read.
private class CountingBody < IO
  getter count = 0_i64

  def initialize(@io : IO)
  end

  def read(slice : Bytes) : Int32
    read = @io.read(slice)
    @count += read
    read
  end

  def write(slice : Bytes) : NoReturn
    raise IO::Error.new("read only")
  end

  def close : Nil
    @io.close
  end
end

# Counts the bytes handlers behind it take from the request body.
private class CountBytes
  include HTTP::Handler

  getter body : CountingBody?

  def count : Int64
    @body.try(&.count) || 0_i64
  end

  def call(context : HTTP::Server::Context)
    if io = context.request.body
      context.request.body = @body = CountingBody.new(io)
    end
    call_next(context)
  end
end

private def with_server(limit : UInt64, handler : Azu::Handler::CSRF, probe : CountBytes, &)
  with_body_limit(limit) do
    server = HTTP::Server.new([probe, handler] of HTTP::Handler) do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      context.response.print "endpoint read #{body.bytesize}"
    end
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield
    begin
      yield address
    ensure
      server.close
    end
  end
end

# Yields *head* and then fails the test if read again: a client that stalls after the token part.
private class StalledBody < IO
  getter stalled_reads = 0

  def initialize(@head : String)
    @io = IO::Memory.new(@head)
    @served = false
  end

  def read(slice : Bytes) : Int32
    return @io.read(slice).tap { @served = true } unless @served
    @stalled_reads += 1
    raise IO::TimeoutError.new("the client stalled")
  end

  def write(slice : Bytes) : NoReturn
    raise IO::Error.new("read only")
  end
end

private LIMIT = 4096_u64

private def with_body_limit(limit : UInt64 = LIMIT, &)
  upload = Azu.current_config.upload
  previous = upload.max_file_size
  upload.max_file_size = limit
  yield
ensure
  upload.max_file_size = previous.not_nil! if upload && previous
end

private def csrf_handler : Azu::Handler::CSRF
  Azu::Handler::CSRF.new(secret_key: "s" * 40, secure_cookies: false)
end

private def issue_token(handler : Azu::Handler::CSRF) : String
  context, _ = create_context("GET", "/form")
  handler.token(context)
end

private def multipart(boundary : String, parts : Array(String)) : String
  parts.join + "--#{boundary}--\r\n"
end

private def text_part(boundary : String, name : String, value : String) : String
  "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
end

private def file_part(boundary : String, name : String, content : String, filename = "a.txt") : String
  "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\nContent-Type: text/plain\r\n\r\n#{content}\r\n"
end

# Runs *body* through the handler as a POST with the token cookie; returns the context, the body the next handler read
# (nil when it was not called) and the bytes taken from the original body.
private def post_through(handler, token : String?, content_type : String, body : String, extra = HTTP::Headers.new, cookie = true, consume = true)
  seen = nil.as(String?)
  handler.next = ->(context : HTTP::Server::Context) { seen = consume ? (context.request.body.try(&.gets_to_end) || "") : "" }
  headers = HTTP::Headers{"Content-Type" => content_type, "Content-Length" => body.bytesize.to_s}
  headers["Cookie"] = "csrf_token=#{token}" if token && cookie
  extra.each { |name, values| headers[name] = values }
  request = HTTP::Request.new("POST", "/save", headers)
  counting = CountingBody.new(IO::Memory.new(body))
  request.body = counting
  io = IO::Memory.new
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
  handler.call(context)
  {context, seen, counting.count}
end

describe "Azu::Handler::CSRF request bodies" do
  describe "a urlencoded form" do
    it "passes with the token in the body, and the endpoint reads the whole body afterwards" do
      handler = csrf_handler
      token = issue_token(handler)
      body = "name=ann&_csrf=#{URI.encode_www_form(token)}&x=1"
      context, seen, _ = post_through(handler, token, "application/x-www-form-urlencoded", body)
      context.response.status_code.should eq 200
      seen.should eq body
    end

    it "matches the content type whatever its case" do
      handler = csrf_handler
      token = issue_token(handler)
      body = "_csrf=#{URI.encode_www_form(token)}"
      _, seen, _ = post_through(handler, token, "Application/X-WWW-Form-Urlencoded; charset=UTF-8", body)
      seen.should eq body
    end

    it "refuses a wrong token with 403 and does not call the endpoint" do
      handler = csrf_handler
      token = issue_token(handler)
      context, seen, _ = post_through(handler, token, "application/x-www-form-urlencoded", "_csrf=nope")
      context.response.status_code.should eq 403
      seen.should be_nil
    end

    it "does not read the body of a request that has no token cookie" do
      handler = csrf_handler
      context, seen, read = post_through(handler, nil, "application/x-www-form-urlencoded", "a=" + "x" * 2000)
      context.response.status_code.should eq 403
      seen.should be_nil
      read.should eq 0
    end

    it "does not read the body when the header carries the token" do
      handler = csrf_handler
      token = issue_token(handler)
      body = "a=" + "x" * 3000
      context, seen, read = post_through(handler, token, "application/x-www-form-urlencoded", body, HTTP::Headers{"X-CSRF-TOKEN" => token}, consume: false)
      context.response.status_code.should eq 200
      read.should eq 0
      seen.should eq ""
    end

    it "answers 413, not 403, for a body over the limit, after reading at most limit + 1 bytes" do
      with_body_limit do
        handler = csrf_handler
        token = issue_token(handler)
        body = "_csrf=#{URI.encode_www_form(token)}&a=" + "x" * 100_000
        # chunked-like: no Content-Length to reject on
        headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Cookie" => "csrf_token=#{token}"}
        request = HTTP::Request.new("POST", "/save", headers)
        counting = CountingBody.new(IO::Memory.new(body))
        request.body = counting
        called = false
        handler.next = ->(context : HTTP::Server::Context) { called = true }
        io = IO::Memory.new
        context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
        handler.call(context)

        context.response.status_code.should eq 413
        context.response.headers["Connection"].should eq "close"
        called.should be_false
        counting.count.should eq(LIMIT.to_i64 + 1)
      end
    end

    it "answers 413 without reading when Content-Length already declares too much" do
      with_body_limit do
        handler = csrf_handler
        token = issue_token(handler)
        headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Cookie" => "csrf_token=#{token}", "Content-Length" => "999999"}
        request = HTTP::Request.new("POST", "/save", headers)
        counting = CountingBody.new(IO::Memory.new("a=b"))
        request.body = counting
        context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
        handler.next = ->(c : HTTP::Server::Context) { }
        handler.call(context)
        context.response.status_code.should eq 413
        counting.count.should eq 0
      end
    end

    it "accepts a body of exactly the limit" do
      with_body_limit do
        handler = csrf_handler
        token = issue_token(handler)
        prefix = "_csrf=#{URI.encode_www_form(token)}&a="
        body = prefix + "x" * (LIMIT.to_i - prefix.bytesize)
        body.bytesize.should eq LIMIT
        context, seen, _ = post_through(handler, token, "application/x-www-form-urlencoded", body)
        context.response.status_code.should eq 200
        seen.should eq body
      end
    end

    it "reads no more than max_form_size, 1 MB by default, even where the endpoint would take more" do
      Azu::Handler::CSRF.new.max_form_size.should eq 1_048_576
      with_body_limit(10_000_000_u64) do
        handler = csrf_handler
        handler.max_form_size = 2_000_u64
        token = issue_token(handler)
        context, seen, read = post_through(handler, token, "application/x-www-form-urlencoded", "a=" + "x" * 3_000)
        context.response.status_code.should eq 413
        seen.should be_nil
        read.should eq 0 # Content-Length said so
      end
    end

    it "keeps non-UTF-8 bytes of the body intact for the endpoint" do
      handler = csrf_handler
      token = issue_token(handler)
      body = String.new(Bytes[0xff, 0xfe, 0x26]) + "_csrf=#{URI.encode_www_form(token)}"
      _, seen, _ = post_through(handler, token, "application/x-www-form-urlencoded", body)
      seen.try(&.to_slice).should eq body.to_slice
    end
  end

  describe "a multipart form" do
    boundary = "XyZ"
    type = "multipart/form-data; boundary=XyZ"

    it "passes with the token before the files, and the endpoint reads the whole body, beyond the scan limit" do
      with_body_limit(1_000_000_u64) do
        handler = csrf_handler
        token = issue_token(handler)
        body = multipart(boundary, [text_part(boundary, "title", "t"), text_part(boundary, "_csrf", token), file_part(boundary, "doc", "z" * 200_000)])
        context, seen, _ = post_through(handler, token, type, body)
        context.response.status_code.should eq 200
        seen.should eq body
      end
    end

    it "refuses a token that follows a file part (403), documented rule" do
      handler = csrf_handler
      token = issue_token(handler)
      body = multipart(boundary, [file_part(boundary, "doc", "z"), text_part(boundary, "_csrf", token)])
      context, seen, _ = post_through(handler, token, type, body)
      context.response.status_code.should eq 403
      seen.should be_nil
    end

    it "refuses a token that sits in a file's content" do
      handler = csrf_handler
      token = issue_token(handler)
      inner = "\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n#{token}"
      body = multipart(boundary, [file_part(boundary, "doc", inner)])
      post_through(handler, token, type, body)[0].response.status_code.should eq 403
    end

    it "refuses a token beyond the scan limit" do
      with_body_limit(1_000_000_u64) do
        handler = csrf_handler
        token = issue_token(handler)
        body = multipart(boundary, [text_part(boundary, "pad", "p" * 70_000), text_part(boundary, "_csrf", token)])
        post_through(handler, token, type, body)[0].response.status_code.should eq 403
      end
    end

    it "reads at most the scan limit of a large body whose walk never decides" do
      with_body_limit(10_000_000_u64) do
        handler = csrf_handler
        token = issue_token(handler)
        body = multipart(boundary, [text_part(boundary, "pad", "z" * 5_000_000)])
        _, _, read = post_through(handler, token, type, body)
        read.should eq Azu::Handler::CSRF::MULTIPART_SCAN_LIMIT.to_i64
      end
    end

    it "stops reading as soon as the walk is decided: at the first file part" do
      with_body_limit(10_000_000_u64) do
        handler = csrf_handler
        token = issue_token(handler)
        body = multipart(boundary, [file_part(boundary, "doc", "z" * 5_000_000)])
        _, _, read = post_through(handler, token, type, body)
        read.should be <= 4096
      end
    end

    it "does not wait for a client that sent the token part and then stalled" do
      handler = csrf_handler
      token = issue_token(handler)
      head = text_part("B", "_csrf", token)
      stalled = StalledBody.new(head)
      headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=B", "Cookie" => "csrf_token=#{token}"}
      request = HTTP::Request.new("POST", "/save", headers)
      request.body = stalled
      seen = nil.as(String?)
      handler.next = ->(context : HTTP::Server::Context) { seen = "reached" }
      context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
      handler.call(context)
      context.response.status_code.should eq 200
      seen.should eq "reached"
      stalled.stalled_reads.should eq 0
    end

    it "walks at most 64 parts: the token as the 64th is found, as the 65th is not" do
      handler = csrf_handler
      token = issue_token(handler)
      filler = ->(count : Int32) { (1..count).map { |n| text_part(boundary, "f#{n}", "v") } }
      found = multipart(boundary, filler.call(63) + [text_part(boundary, "_csrf", token)])
      missed = multipart(boundary, filler.call(64) + [text_part(boundary, "_csrf", token)])
      post_through(handler, token, type, found)[0].response.status_code.should eq 200
      post_through(handler, token, type, missed)[0].response.status_code.should eq 403
    end

    it "refuses a cookie that is not a token it signed before reading any body" do
      handler = csrf_handler
      context, seen, read = post_through(handler, "forged", type, multipart(boundary, [text_part(boundary, "_csrf", "forged")]))
      context.response.status_code.should eq 403
      read.should eq 0
      seen.should be_nil
      urlencoded = post_through(handler, "forged", "application/x-www-form-urlencoded", "_csrf=forged")
      urlencoded[2].should eq 0
    end

    it "does not refuse on the total length: the limit applies to each file, and the endpoint checks it" do
      with_body_limit do
        handler = csrf_handler
        token = issue_token(handler)
        body = multipart(boundary, [text_part(boundary, "_csrf", token), file_part(boundary, "a", "z" * 3000, "a"), file_part(boundary, "b", "z" * 3000, "b")])
        body.bytesize.should be > LIMIT
        context, seen, _ = post_through(handler, token, type, body)
        context.response.status_code.should eq 200
        seen.should eq body
      end
    end

    it "refuses a multipart body without a boundary" do
      handler = csrf_handler
      token = issue_token(handler)
      post_through(handler, token, "multipart/form-data", text_part(boundary, "_csrf", token))[0].response.status_code.should eq 403
    end
  end

  describe "Azu::Handler::CSRF.multipart_field" do
    field = ->(body : String, name : String) { Azu::Handler::CSRF.multipart_field(body.to_slice, "B", name) }

    it "finds a field with CRLF and with bare LF line breaks" do
      field.call("--B\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\ntok\r\n--B--\r\n", "_csrf").should eq "tok"
      field.call("--B\nContent-Disposition: form-data; name=\"_csrf\"\n\ntok\n--B--\n", "_csrf").should eq "tok"
    end

    it "finds a field after an empty one, and an empty value" do
      field.call("--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\n--B\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\ntok\r\n--B--", "_csrf").should eq "tok"
      field.call("--B\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\r\n--B--", "_csrf").should eq ""
    end

    it "reads the header name in any case and a quoted semicolon in another parameter" do
      field.call("--B\r\ncontent-disposition: FORM-DATA; x=\"a;name=\\\"q\\\"\"; Name=\"_csrf\"\r\n\r\ntok\r\n--B--", "_csrf").should eq "tok"
    end

    it "does not take a field that merely ends or starts with the name" do
      field.call("--B\r\nContent-Disposition: form-data; name=\"x_csrf\"\r\n\r\nbad\r\n--B--", "_csrf").should be_nil
      field.call("--B\r\nContent-Disposition: form-data; name=\"_csrf2\"\r\n\r\nbad\r\n--B--", "_csrf").should be_nil
    end

    it "gives up on a repeated name, a repeated filename parameter, filename*, or a missing disposition" do
      field.call("--B\r\nContent-Disposition: form-data; name=\"a\"; name=\"_csrf\"\r\n\r\nbad\r\n--B--", "_csrf").should be_nil
      field.call("--B\r\nContent-Disposition: form-data; name=\"_csrf\"; filename*=UTF-8''a\r\n\r\nbad\r\n--B--", "_csrf").should be_nil
      field.call("--B\r\nContent-Type: text/plain\r\n\r\nbad\r\n--B--", "_csrf").should be_nil
    end

    it "gives up on a value that does not end in the buffer, and on garbage" do
      field.call("--B\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\ntok", "_csrf").should be_nil
      field.call("no boundary here", "_csrf").should be_nil
      field.call("", "_csrf").should be_nil
      field.call("--B", "_csrf").should be_nil
      field.call("--B\r\n", "_csrf").should be_nil
      field.call("--B\xff\xfe\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\ntok\r\n--B--", "_csrf").should eq "tok"
    end
  end

  describe "the multipart walk of hostile bodies" do
    scan = ->(body : Bytes) { Azu::Handler::CSRF.scan_multipart(body, "B", "_csrf") }
    limit = Azu::Handler::CSRF::MULTIPART_SCAN_LIMIT

    bodies = {
      "thousands of tiny parts with CRLF"       => ("--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\n" * 2_500),
      "thousands of tiny parts with LF only"    => ("--B\nContent-Disposition: form-data; name=\"a\"\n\nv\n" * 2_500),
      "the same with non-ASCII bytes"           => ("--B\r\nContent-Disposition: form-data; name=\"é\"\r\n\r\nüüü\r\n" * 1_800),
      "parts that carry no disposition"         => ("--B\n\n\n" * 10_000),
      "only line breaks"                        => ("\n" * limit),
      "only carriage returns and line breaks"   => ("\r\n" * (limit // 2)),
      "near-miss delimiters"                    => ("\n--" + "B" * 3 + "x" + "\n--BB" * 10_000),
      "an endless header block"                 => ("--B\r\n" + "X-H: y\r\n" * 10_000),
      "one huge header line"                    => ("--B\r\nContent-Disposition: form-data; name=\"" + "a" * limit),
      "a delimiter preceded by a long preamble" => ("p" * (limit - 100) + "\r\n--B\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\nt\r\n--B--"),
    }

    bodies.each do |name, body|
      it "takes a bounded time on #{name}" do
        bytes = body.to_slice[0, Math.min(body.bytesize, limit)]
        started = Time.instant
        20.times { scan.call(bytes) }
        (Time.instant - started).should be < 1.5.seconds # the quadratic walk took 40 s for 20 of the first kind
      end
    end

    it "still finds the field behind a preamble, and in a body without carriage returns" do
      scan.call(bodies["a delimiter preceded by a long preamble"].to_slice).should eq({"t", true})
      scan.call("--B\nContent-Disposition: form-data; name=\"_csrf\"\n\ntok\n--B--".to_slice).should eq({"tok", true})
    end

    it "is undecided while the field may still come, and decided once it cannot" do
      scan.call("--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv".to_slice).should eq({nil, false})
      scan.call("--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n--B\r\nContent-Dis".to_slice).should eq({nil, false})
      scan.call("--B\r\nContent-Disposition: form-data; name=\"a\"; filename=\"f\"\r\n\r\nv\r\n--B--".to_slice).should eq({nil, true})
      scan.call("--B--".to_slice).should eq({nil, true})
      scan.call("".to_slice).should eq({nil, false})
    end
  end

  describe "over a real connection" do
    # Sends the head, then up to *total* bytes of *piece* as chunks of a chunked body (or, with a Content-Length in the
    # head, as the raw body) until the server answers or closes; returns the status line the server answered.
    stream = ->(address : Socket::IPAddress, head : String, piece : String, total : Int32, chunked : Bool) {
      socket = TCPSocket.new(address.address, address.port)
      socket << head << "\r\n\r\n"
      socket.flush
      status = Channel(String?).new(1)
      spawn do
        line = begin
          socket.gets
        rescue IO::Error
          nil
        end
        status.send(line)
      end
      sent = 0
      answered = nil.as(String?)
      begin
        while sent < total
          select
          when line = status.receive
            answered = line || "closed"
            break
          else
          end
          chunked ? socket << piece.bytesize.to_s(16) << "\r\n" << piece << "\r\n" : socket << piece
          socket.flush
          sent += piece.bytesize
        end
        socket << "0\r\n\r\n" if chunked && !answered
        socket.flush
      rescue IO::Error
      end
      answered ||= select
      when line = status.receive
        line || "closed"
      when timeout(5.seconds)
        "timeout"
      end
      socket.close
      {answered, sent}
    }

    it "refuses a streamed oversize urlencoded body with 413 after reading limit + 1 bytes" do
      handler = csrf_handler
      token = issue_token(handler)
      probe = CountBytes.new
      with_server(100_000_u64, handler, probe) do |address|
        head = "POST /save HTTP/1.1\r\nHost: x\r\nConnection: close\r\nCookie: csrf_token=#{token}\r\nContent-Type: application/x-www-form-urlencoded\r\nTransfer-Encoding: chunked"
        status, sent = stream.call(address, head, "a=" + "x" * 8190, 200_000_000, true)
        status.to_s.should start_with("HTTP/1.1 413")
        probe.count.should eq 100_001
        sent.should be < 20_000_000
      end
    end

    it "refuses an oversize Content-Length with 413 without reading any of the body" do
      handler = csrf_handler
      token = issue_token(handler)
      probe = CountBytes.new
      with_server(100_000_u64, handler, probe) do |address|
        head = "POST /save HTTP/1.1\r\nHost: x\r\nConnection: close\r\nCookie: csrf_token=#{token}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 500000000"
        status, _ = stream.call(address, head, "a=" + "x" * 1000, 3000, false)
        status.to_s.should start_with("HTTP/1.1 413")
        probe.count.should eq 0
      end
    end

    it "refuses a streamed multipart body that has no token after reading only the scan limit" do
      handler = csrf_handler
      token = issue_token(handler)
      probe = CountBytes.new
      with_server(100_000_u64, handler, probe) do |address|
        head = "POST /save HTTP/1.1\r\nHost: x\r\nConnection: close\r\nCookie: csrf_token=#{token}\r\nContent-Type: multipart/form-data; boundary=B\r\nTransfer-Encoding: chunked"
        piece = "--B\r\nContent-Disposition: form-data; name=\"pad\"\r\n\r\n" + "x" * 8000
        status, sent = stream.call(address, head, piece, 200_000_000, true)
        status.to_s.should start_with("HTTP/1.1 403")
        probe.count.should eq Azu::Handler::CSRF::MULTIPART_SCAN_LIMIT.to_i64
        sent.should be < 20_000_000
      end
    end

    it "lets a valid multipart upload reach the endpoint whole" do
      handler = csrf_handler
      token = issue_token(handler)
      probe = CountBytes.new
      with_server(1_000_000_u64, handler, probe) do |address|
        body = multipart("B", [text_part("B", "_csrf", token), file_part("B", "doc", "z" * 300_000)])
        head = "POST /save HTTP/1.1\r\nHost: x\r\nConnection: close\r\nCookie: csrf_token=#{token}\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: #{body.bytesize}"
        status, _ = stream.call(address, head, body, body.bytesize, false)
        status.to_s.should start_with("HTTP/1.1 200")
        probe.count.should eq body.bytesize.to_i64
      end
    end

    it "lets a valid urlencoded form reach the endpoint whole" do
      handler = csrf_handler
      token = issue_token(handler)
      probe = CountBytes.new
      with_server(100_000_u64, handler, probe) do |address|
        body = "a=1&_csrf=#{URI.encode_www_form(token)}"
        head = "POST /save HTTP/1.1\r\nHost: x\r\nConnection: close\r\nCookie: csrf_token=#{token}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: #{body.bytesize}"
        status, _ = stream.call(address, head, body, body.bytesize, false)
        status.to_s.should start_with("HTTP/1.1 200")
      end
    end
  end
end
