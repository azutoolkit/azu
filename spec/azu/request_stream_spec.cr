require "../spec_helper"

# How Crystal's own server frames the request whose headers are *block*: where the headers end and the body length,
# `:chunked`, `:huge` (more than Int64 holds), or nil when it refuses the request (a status, a raise, or `Content-Length`
# with `Transfer-Encoding`, which `HTTP::Server::RequestProcessor` answers 400).
private def stdlib_framing(block : String) : {Int64, Int64 | Symbol}?
  io = IO::Memory.new(block)
  request = HTTP::Request.from_io(io)
  return unless request.is_a?(HTTP::Request)
  return if request.headers.has_key?("Content-Length") && request.headers.has_key?("Transfer-Encoding")
  length = case body = request.body
           when Nil                      then 0_i64
           when HTTP::ChunkedContent     then :chunked
           when HTTP::FixedLengthContent then body.read_remaining > Int64::MAX ? :huge : body.read_remaining.to_i64
           else                               :other
           end
  {io.pos.to_i64, length}
rescue ArgumentError
  nil
end

# Where `RequestStream` sees the headers end, fed a byte at a time, and the body length it reads (nil: unknown).
private def stream_framing(block : String) : {Int64, Int64?}?
  stream = Azu::RequestStream.new
  block.to_slice.each_with_index do |byte, index|
    stream.feed(Bytes[byte])
    return {index.to_i64 + 1, stream.body_length} if stream.parsed == 1
  end
  nil
end

# What the stream makes of *bytes* fed in pieces of *sizes* (cycled): the requests seen, the last length, the state.
private def stream_state(bytes : Bytes, sizes : Array(Int32)) : {Int32, Int64?, Bool, Bool}
  stream = Azu::RequestStream.new
  offset = 0
  piece = 0
  while offset < bytes.size
    size = Math.min(sizes[piece % sizes.size], bytes.size - offset)
    stream.feed(bytes[offset, size])
    offset += size
    piece += 1
  end
  {stream.parsed, stream.body_length, stream.partial?, stream.unknown_body?}
end

private def header_block(lines : Array(String), eol : String = "\r\n") : String
  String.build do |io|
    io << "POST /body HTTP/1.1" << eol << "Host: x" << eol
    lines.each { |line| io << line << eol }
    io << eol
  end
end

# Agreement, or the unknown-length fallback: never a length the server's parser does not use.
private def check_framing(block : String) : Symbol
  expected = stdlib_framing(block)
  got = stream_framing(block)
  return :refused unless expected # the server answers 400/501 (or drops) and closes: no next request to time
  got.should_not be_nil
  ends, length = got.not_nil!
  ends.should eq expected[0]
  case want = expected[1]
  when Int64
    fail "#{block.inspect}: the stream read #{length}, the server #{want}" unless length.nil? || length == want
    length.nil? ? :fallback : :exact
  else
    fail "#{block.inspect}: the stream read #{length}, the server #{want}" unless length.nil?
    :fallback
  end
end

NAMES = ["Content-Length", "content-length", "CONTENT-LENGTH", "Content_Length", "content_length", "CONTENT_LENGTH",
         "Content-length", "cOnTeNt_LeNgTh", "Content-Lengt", "Content-Lengthh", "Content Length", "Content-Length ",
         " Content-Length", "\tContent-Length", "Content-Length\t", "X-Content-Length", "Content\u0000Length",
         "Transfer-Encoding", "transfer-encoding", "Transfer_Encoding", "TRANSFER_ENCODING", "transfer_Encoding",
         "Transfer-Encoding ", " Transfer-Encoding", "Transfer-Encodin", ""]
VALUES = ["5", "05", "0", "00000000000000000005", " 5", "  5", "\t5", "5 ", "5\t", " 5 ", "+5", "-5", "5x", "x5", "",
          "0x5", "5.0", "5,5", "5, 5", "\v5", "\f5", "999999999999999999", "9223372036854775807",
          "9223372036854775808", "18446744073709551615", "18446744073709551616", "chunked", "Chunked", "gzip, chunked",
          "chunked ", " chunked", "identity", "5\r", "\r5", "#{" " * 80}5"]
EXTRA = ["X-A: b", " folded", "\tfolded", "X-Pad: #{"a" * 200}", "#{"N" * 80}: v", "#{"N" * 80}", "no colon",
         ": empty name", "X-A: b\rc", "Expect: 100-continue", "Content-Length: 5", "content_length: 5",
         "Content-Length: 6", "Transfer-Encoding: chunked", "Transfer_Encoding: chunked"]

describe Azu::RequestStream do
  it "reads the framing headers as HTTP::Headers matches names: any case, _ as -" do
    ["Content-Length", "content-length", "CONTENT-LENGTH", "Content_Length", "content_length", "cOnTeNt_LeNgTh"].each do |name|
      stream_framing(header_block(["#{name}: 5"])).not_nil![1].should eq 5
    end
    ["Transfer-Encoding", "transfer_encoding", "TRANSFER_ENCODING"].each do |name|
      stream_framing(header_block(["#{name}: chunked"])).not_nil![1].should be_nil
    end
  end

  it "reads plain lengths exactly, with or without spaces after the colon, CRLF or LF" do
    {"Content-Length: 5" => 5_i64, "Content-Length:5" => 5_i64, "Content-Length: \t 12" => 12_i64,
     "Content-Length: 0" => 0_i64, "Content-Length: 007" => 7_i64, "Content-Length: 999999999999999999" => 999999999999999999_i64}.each do |line, length|
      ["\r\n", "\n"].each do |eol|
        block = header_block([line], eol)
        stream_framing(block).not_nil![1].should eq length
        check_framing(block).should eq :exact
      end
    end
  end

  it "does not guess a length it cannot read exactly as the server does" do
    ["Content-Length: 5\r\nContent-Length: 5", "Content-Length: 5\r\ncontent_length: 6", "Content-Length: 5 ",
     "Content-Length: +5", "Content-Length: -5", "Content-Length: 5x", "Content-Length:", "Content-Length: 0x5",
     "Content-Length: 9223372036854775808", "Content-Length: #{"0" * 18}5", "Content-Length: #{" " * 80}5",
     "Transfer-Encoding: chunked", "Transfer_Encoding: chunked\r\nContent-Length: 5", "Transfer-Encoding: gzip",
     "Content-Length : 5", " Content-Length: 5", "X-A: b\r\n folded", "no colon", ": no name",
     "X-A: b\rc\r\nContent-Length: 5"].each do |lines|
      stream_framing(header_block([lines])).not_nil![1].should be_nil
    end
  end

  it "tells a long line that is not a framing header apart, and keeps the length of the request" do
    stream_framing(header_block(["X-Pad: #{"a" * 500}", "Content-Length: 5", "#{"N" * 90}: v"])).not_nil![1].should eq 5
  end

  it "frames every request of a generated corpus as Crystal's parser does, or as unknown" do
    counts = Hash(Symbol, Int32).new(0)
    ["\r\n", "\n"].each do |eol|
      NAMES.each do |name|
        VALUES.each do |value|
          counts[check_framing(header_block(["#{name}: #{value}"], eol))] += 1
          counts[check_framing(header_block(["#{name}:#{value}"], eol))] += 1
        end
      end
    end
    random = Random.new(20261027)
    pool = NAMES.flat_map { |name| VALUES.sample(3, random).map { |value| "#{name}: #{value}" } } + EXTRA
    3000.times do
      lines = Array.new(random.rand(1..4)) { pool.sample(random) }
      counts[check_framing(header_block(lines, random.rand(2) == 0 ? "\r\n" : "\n"))] += 1
    end
    counts[:exact].should be > 100
    counts[:fallback].should be > 100
    counts[:refused].should be > 100
  end

  it "finds the same framing however the bytes are split into reads" do
    random = Random.new(7)
    next_request = "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /partial HTTP/1.1\r\n"
    [header_block(["Content_Length: 5", "X-Pad: #{"a" * 100}"]) + "hello" + next_request,
     header_block(["content-length: 12"], "\n") + "z" * 12 + next_request,
     header_block(["Transfer_Encoding: chunked"]) + "5\r\nhello\r\n0\r\n\r\n",
     header_block(["X-A: b\r\n folded", "Content-Length: 5"]) + "hello"].each do |text|
      bytes = text.to_slice
      whole = stream_state(bytes, [bytes.size])
      stream_state(bytes, [1]).should eq whole
      (1...bytes.size).each { |at| stream_state(bytes, [at, bytes.size]).should eq whole }
      20.times { stream_state(bytes, Array.new(5) { random.rand(1..40) }).should eq whole }
    end
  end
end
