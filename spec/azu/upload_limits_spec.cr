require "../spec_helper"
require "http/client"

private struct UploadProbeRequest
  include Azu::Request

  getter title : String?
end

private struct UploadProbeResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

# Reports what the endpoint saw of the uploads: field, temp path, permissions, size.
private struct UploadProbeEndpoint
  include Azu::Endpoint(UploadProbeRequest, UploadProbeResponse)

  post "/upload"

  def call : UploadProbeResponse
    lines = params.files.map do |name, file|
      mode = ::File.info(file.temp_path).permissions.value.to_s(8)
      "#{name}|#{file.temp_path}|#{mode}|#{::File.size(file.temp_path)}"
    end
    UploadProbeResponse.new(lines.join("\n"))
  end
end

# Counts the bytes taken from the request body.
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

private def part(name : String, value : String, filename : String? = nil) : String
  disposition = %(form-data; name="#{name}") + (filename ? %(; filename="#{filename}") : "")
  "--B\r\nContent-Disposition: #{disposition}\r\n\r\n#{value}\r\n"
end

private def with_upload_server(temp_dir : String, **limits, &)
  Dir.mkdir_p(temp_dir)
  app = Azu::App.new
  upload = app.config.upload
  upload.temp_dir = temp_dir
  upload.max_file_size = limits[:file]? || 10_000_u64
  upload.max_request_size = limits[:request]? || 40_000_u64
  upload.max_parts = limits[:parts]? || 100
  upload.max_files = limits[:files]? || 20
  app.routes { post "/upload", UploadProbeEndpoint }
  probe = CountBytes.new
  server = app.server([probe] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  200.times do
    TCPSocket.new(address.address, address.port).close
    break
  rescue Socket::ConnectError
    sleep 10.milliseconds
  end
  begin
    yield address, probe
  ensure
    server.close
    FileUtils.rm_rf(temp_dir)
  end
end

# Sends the head and then *pieces* until the server answers or closes; returns the status line and the bytes sent.
private def stream(address : Socket::IPAddress, head : String, pieces : Iterator(String), chunked : Bool) : {String, Int64}
  socket = TCPSocket.new(address.address, address.port)
  socket << head << "\r\n\r\n"
  socket.flush
  status = ::Channel(String?).new(1)
  spawn do
    line = begin
      socket.gets
    rescue IO::Error
      nil
    end
    status.send(line)
  end
  sent = 0_i64
  answered = nil.as(String?)
  begin
    pieces.each do |piece|
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
  when timeout(10.seconds)
    "timeout"
  end
  socket.close
  {answered, sent}
end

private def post_head(extra : String) : String
  "POST /upload HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: multipart/form-data; boundary=B\r\n#{extra}"
end

private def temp_files(dir : String) : Array(String)
  Dir.children(dir)
end

describe "multipart limits" do
  dir = Path[Dir.tempdir, "azu_upload_limits_spec"].to_s

  it "gives a stored upload a private temp file that is gone when the request is done" do
    with_upload_server(dir) do |address, _|
      body = part("title", "t") + part("doc", "hello", "a.txt") + "--B--\r\n"
      response = HTTP::Client.new(address.address, address.port).post("/upload", HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=B"}, body)
      response.status_code.should eq 200
      name, path, mode, size = response.body.split('|')
      {name, mode, size}.should eq({"doc", "600", "5"})
      path.should start_with(dir)
      ::File.exists?(path).should be_false
      temp_files(dir).should be_empty
    end
  end

  it "keeps a file name from leaving the temp directory" do
    with_upload_server(dir) do |address, _|
      body = part("doc", "x", "../../etc/pass wd.txt") + "--B--\r\n"
      response = HTTP::Client.new(address.address, address.port).post("/upload", HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=B"}, body)
      response.status_code.should eq 200
      path = response.body.split('|')[1]
      Path[path].parent.to_s.should eq dir
      ::File.basename(path).should_not contain("/")
      ::File.basename(path).should end_with("etc_pass_wd.txt")
    end
  end

  it "replaces and deletes the file a second one of the same field name supersedes" do
    with_upload_server(dir) do |address, _|
      body = part("doc", "one", "a.txt") + part("doc", "two", "b.txt") + "--B--\r\n"
      response = HTTP::Client.new(address.address, address.port).post("/upload", HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=B"}, body)
      response.body.lines.size.should eq 1
      temp_files(dir).should be_empty
    end
  end

  it "answers 413 at once, reading nothing, when Content-Length is over max_request_size" do
    with_upload_server(dir) do |address, probe|
      status, _ = stream(address, post_head("Content-Length: 9999999999"), ["--B\r\n"].each, false)
      status.should start_with("HTTP/1.1 413")
      probe.count.should eq 0
      temp_files(dir).should be_empty
    end
  end

  it "stops a chunked stream of files that are each within the limit at max_request_size, with no temp file left" do
    with_upload_server(dir) do |address, probe|
      pieces = (1..).each.map { |n| part("f#{n}", "z" * 6_000, "f#{n}.bin") }
      status, _ = stream(address, post_head("Transfer-Encoding: chunked"), pieces.first(2_000), true)
      status.should start_with("HTTP/1.1 413")
      probe.count.should be <= 40_100 # the limit plus the byte that shows there is more
      temp_files(dir).should be_empty
    end
  end

  it "answers 413 for more parts than max_parts, and for more files than max_files" do
    with_upload_server(dir, parts: 100) do |address, _|
      body = (1..150).map { |n| part("f#{n}", "v") }.join + "--B--\r\n"
      status, _ = stream(address, post_head("Content-Length: #{body.bytesize}"), [body].each, false)
      status.should start_with("HTTP/1.1 413")
    end
    with_upload_server(dir, files: 20, request: 1_000_000_u64) do |address, _|
      body = (1..25).map { |n| part("f#{n}", "v", "f#{n}.txt") }.join + "--B--\r\n"
      status, _ = stream(address, post_head("Content-Length: #{body.bytesize}"), [body].each, false)
      status.should start_with("HTTP/1.1 413")
      temp_files(dir).should be_empty
    end
  end

  it "still takes a file of exactly the per-file limit inside the request limit" do
    with_upload_server(dir) do |address, _|
      body = part("doc", "z" * 10_000, "big.bin") + "--B--\r\n"
      response = HTTP::Client.new(address.address, address.port).post("/upload", HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=B"}, body)
      response.status_code.should eq 200
      response.body.split('|').last.should eq "10000"
    end
  end
end
