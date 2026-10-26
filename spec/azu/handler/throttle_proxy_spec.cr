require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

# The server accepts connections: a plain Fiber.yield does not promise that on a loaded machine.
private def wait_until_listening(address : Socket::IPAddress) : Nil
  200.times do
    TCPSocket.new(address.address, address.port).close
    return
  rescue Socket::ConnectError
    sleep 10.milliseconds
  end
  raise "the spec server did not start"
end

private alias CA = Azu::Handler::ClientAddress

private def throttle(threshold = 1, trusted = [] of String, **options) : Azu::Handler::Throttle
  handler = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: threshold, blacklist: options[:blacklist]? || [] of String,
    whitelist: options[:whitelist]? || [] of String, trusted_proxies: trusted, ipv6_prefix: options[:ipv6_prefix]? || 64,
    max_clients: options[:max_clients]? || 100_000)
  handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
  handler
end

# Status of a request from *peer* carrying the X-Forwarded-For header lines *forwarded*.
private def status(handler, peer : String, forwarded : Array(String) = [] of String) : Int32
  headers = HTTP::Headers.new
  forwarded.each { |line| headers.add("X-Forwarded-For", line) }
  context, _ = create_context("GET", "/", headers)
  context.request.remote_address = Socket::IPAddress.new(peer, 4000)
  handler.call(context)
  context.response.status_code
end

private def serve(trusted : Array(String), &)
  handler = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: 1, blacklist: [] of String, whitelist: [] of String, trusted_proxies: trusted)
  server = HTTP::Server.new([handler] of HTTP::Handler) { |context| context.response.print "OK" }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  wait_until_listening(address)
  begin
    yield address
  ensure
    server.close
  end
end

describe Azu::Handler::ClientAddress do
  describe ".parse" do
    {
      "1.2.3.4"                 => "1.2.3.4",
      " 1.2.3.4 "               => "1.2.3.4",
      "1.2.3.4:8080"            => "1.2.3.4",
      "::ffff:1.2.3.4"          => "1.2.3.4",
      "[::ffff:1.2.3.4]:99"     => "1.2.3.4",
      "::FFFF:0102:0304"        => "1.2.3.4",
      "::1"                     => "0:0:0:0:0:0:0:1",
      "[::1]"                   => "0:0:0:0:0:0:0:1",
      "[::1]:443"               => "0:0:0:0:0:0:0:1",
      "2001:DB8::8a2e:370:7334" => "2001:db8:0:0:0:8a2e:370:7334",
      "2001:db8:0:0:0:0:0:1"    => "2001:db8:0:0:0:0:0:1",
      "::"                      => "0:0:0:0:0:0:0:0",
      "64:ff9b::1.2.3.4"        => "64:ff9b:0:0:0:0:102:304",
      "255.255.255.255:65535"   => "255.255.255.255",
    }.each do |text, expected|
      it "reads #{text.inspect}" do
        CA.parse(text).try { |address| CA.to_s(address) }.should eq expected
      end
    end

    [
      "", " ", "unknown", "_hidden", "for=1.2.3.4", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.04", "01.2.3.4", "1.2.3.4:",
      "1.2.3.4:65536", "1.2.3.4:80a", "1.2.3.4:-1", "1.2.3.4 5", "1.2.3.4/24", "evil.example", "localhost", "0x7f.0.0.1",
      "::1::2", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "12345::1", "g::1", "fe80::1%eth0", "[::1", "[::1]x", "[::1]:", "[::1]:70000",
      "[1.2.3.4", "::1.2.3", "1.2.3.4::1", ":1", "1:", "::ffff:1.2.3.4.5", "٣.٣.٣.٣", "1.2.3.4\r\n", "1.2.3.4\x00", "'1.2.3.4'", "\"1.2.3.4\"",
      "1" * 80, "[" + "1:" * 40 + "]",
    ].each do |text|
      it "refuses #{text.inspect[0, 40]}" do
        CA.parse(text).should be_nil
      end
    end
  end

  describe Azu::Handler::ClientAddress::Networks do
    it "contains exact addresses and CIDR blocks of both families, with mapped addresses as IPv4" do
      networks = CA::Networks.parse(["10.0.0.0/8", "192.168.1.5", "fd00::/8", "::1", "2001:db8::/32", "203.0.113.0/24"])
      ["10.1.2.3", "192.168.1.5", "fd12::1", "::1", "2001:db8:ffff::1", "::ffff:10.9.9.9", "203.0.113.255"].each do |text|
        networks.includes?(CA.parse(text).not_nil!).should be_true
      end
      ["11.0.0.1", "192.168.1.6", "fe00::1", "::2", "2001:db9::1", "203.0.114.0", "::ffff:11.0.0.1"].each do |text|
        networks.includes?(CA.parse(text).not_nil!).should be_false
      end
    end

    it "treats /0 as everything of its family and /32 as one address" do
      CA::Networks.parse(["0.0.0.0/0"]).includes?(CA.parse("8.8.8.8").not_nil!).should be_true
      CA::Networks.parse(["0.0.0.0/0"]).includes?(CA.parse("::1").not_nil!).should be_false
      CA::Networks.parse(["8.8.8.8/32"]).includes?(CA.parse("8.8.8.9").not_nil!).should be_false
      CA::Networks.parse(["::/0"]).includes?(CA.parse("2001::1").not_nil!).should be_true
    end

    it "normalizes the base of a block with host bits set" do
      CA::Networks.parse(["10.1.2.3/8"]).includes?(CA.parse("10.200.0.1").not_nil!).should be_true
    end

    ["", "nope", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/", "10.0.0.0/8/8", "::1/129", "10.0.0.0/ 8", "10.0.0.0/x", "[::1]", "1.2.3.4:80", "1.2.3.4:80/24", "*"].each do |entry|
      it "refuses the entry #{entry.inspect}" do
        expect_raises(ArgumentError, /trusted_proxies/) { CA::Networks.parse([entry]) }
      end
    end
  end

  describe ".client" do
    trusted = CA::Networks.parse(["10.0.0.0/8", "fd00::/8"])
    client = ->(peer : String, lines : Array(String)?) {
      CA.client(CA.parse(peer).not_nil!, lines, trusted).try { |address| CA.to_s(address) }
    }

    it "is the peer when it is not trusted, whatever the header says" do
      client.call("6.6.6.6", ["1.1.1.1"]).should eq "6.6.6.6"
    end

    it "is the right-most address that is not trusted" do
      client.call("10.0.0.1", ["1.1.1.1, 2.2.2.2"]).should eq "2.2.2.2"
      client.call("10.0.0.1", ["9.9.9.9, 1.1.1.1, 10.0.0.2, 10.0.0.3"]).should eq "1.1.1.1"
    end

    it "reads several header lines as one list, in order" do
      client.call("10.0.0.1", ["9.9.9.9", "1.1.1.1", "10.0.0.2"]).should eq "1.1.1.1"
      client.call("10.0.0.1", ["9.9.9.9, 1.1.1.1", "2.2.2.2"]).should eq "2.2.2.2"
    end

    it "copes with whitespace, ports, brackets and mapped addresses" do
      client.call("10.0.0.1", ["  1.1.1.1:5555 ,\t10.0.0.9:1  "]).should eq "1.1.1.1"
      client.call("10.0.0.1", ["[2001:db8::7]:443, ::ffff:10.0.0.2"]).should eq "2001:db8:0:0:0:0:0:7"
      client.call("::ffff:10.0.0.1", ["1.1.1.1"]).should eq "1.1.1.1"
    end

    it "is the peer when there is no header or an empty one, and nil when the hops name no client" do
      client.call("10.0.0.1", nil).should eq "10.0.0.1"
      client.call("10.0.0.1", [""]).should eq "10.0.0.1"
      client.call("10.0.0.1", ["10.0.0.2, fd00::5"]).should be_nil
    end

    it "is nil when a hop it has to read is garbage, even if a good one stands further left" do
      client.call("10.0.0.1", ["1.1.1.1, garbage"]).should be_nil
      client.call("10.0.0.1", ["1.1.1.1, , 10.0.0.2"]).should be_nil
      client.call("10.0.0.1", ["1.1.1.1,"]).should be_nil
      client.call("10.0.0.1", ["unknown"]).should be_nil
    end

    it "does not read past a client's garbage to its left" do
      client.call("10.0.0.1", ["bogus, 2.2.2.2"]).should eq "2.2.2.2"
    end

    it "does not believe a chain longer than it reads (nil) and reads a long chain that ends early" do
      client.call("10.0.0.1", [(["10.0.0.2"] * 40).join(", ") + ", 1.1.1.1"]).should eq "1.1.1.1"
      client.call("10.0.0.1", ["1.1.1.1, " + (["10.0.0.2"] * 40).join(", ")]).should be_nil
      client.call("10.0.0.1", [(["10.0.0.2"] * 1000).join(", ")]).should be_nil
    end

    it "is the peer without any trusted proxy" do
      CA.to_s(CA.client(CA.parse("10.0.0.1").not_nil!, ["1.1.1.1"], CA::Networks.parse([] of String)).not_nil!).should eq "10.0.0.1"
    end
  end

  describe ".key" do
    it "is the IPv4 address, or the IPv6 network" do
      CA.key(CA.parse("1.2.3.4").not_nil!).should eq "1.2.3.4"
      CA.key(CA.parse("2001:db8:1:2:3:4:5:6").not_nil!).should eq "2001:db8:1:2:0:0:0:0/64"
      CA.key(CA.parse("2001:db8:1:2:3:4:5:6").not_nil!, 48).should eq "2001:db8:1:0:0:0:0:0/48"
    end
  end
end

describe Azu::Handler::Throttle do
  describe "trusted_proxies" do
    it "refuses a bad entry or option when it is built" do
      expect_raises(ArgumentError, /trusted_proxies/) { throttle(trusted: ["not-an-ip"]) }
      expect_raises(ArgumentError) { throttle(ipv6_prefix: 0) }
      expect_raises(ArgumentError) { throttle(ipv6_prefix: 129) }
      expect_raises(ArgumentError) { throttle(max_clients: 0) }
    end

    it "keeps the connection's address as the client by default, and ignores X-Forwarded-For" do
      handler = throttle
      statuses = %w(1.1.1.1 2.2.2.2 3.3.3.3).map { |ip| status(handler, "10.0.0.1", [ip]) }
      statuses.should eq [200, 429, 429]
    end

    it "counts clients behind a trusted proxy separately" do
      handler = throttle(trusted: ["10.0.0.0/8"])
      status(handler, "10.0.0.1", ["1.1.1.1"]).should eq 200
      status(handler, "10.0.0.1", ["2.2.2.2"]).should eq 200
      status(handler, "10.0.0.1", ["1.1.1.1"]).should eq 429
      status(handler, "10.0.0.2", ["2.2.2.2"]).should eq 429
      handler.stats[:tracked_ips].should eq 2
    end

    it "does not let the client pick its key by writing to the left of what the proxy appended" do
      handler = throttle(trusted: ["10.0.0.1"])
      statuses = %w(3.3.3.3 4.4.4.4 5.5.5.5).map { |forged| status(handler, "10.0.0.1", ["#{forged}, 7.7.7.7"]) }
      statuses.should eq [200, 429, 429]
    end

    it "does not let a request from an untrusted peer change its key" do
      handler = throttle(trusted: ["10.0.0.0/8"])
      statuses = %w(1.1.1.1 2.2.2.2 10.0.0.5 3.3.3.3).map { |forged| status(handler, "6.6.6.6", [forged]) }
      statuses.should eq [200, 429, 429, 429]
      handler.stats[:tracked_ips].should eq 1
    end

    it "does not let an untrusted peer frame another client or borrow a whitelisted one" do
      handler = throttle(trusted: ["10.0.0.0/8"], whitelist: ["8.8.8.8"])
      status(handler, "6.6.6.6", ["8.8.8.8"]).should eq 200
      status(handler, "6.6.6.6", ["8.8.8.8"]).should eq 429
      status(handler, "5.5.5.5", ["6.6.6.6"]).should eq 200 # not charged to 6.6.6.6
    end

    it "applies the lists to the client behind a trusted proxy" do
      handler = throttle(trusted: ["10.0.0.1"], whitelist: ["8.8.8.8"], blacklist: ["9.9.9.9"])
      3.times { status(handler, "10.0.0.1", ["8.8.8.8"]).should eq 200 }
      status(handler, "10.0.0.1", ["9.9.9.9"]).should eq 429
      status(handler, "10.0.0.1", ["1.1.1.1"]).should eq 200
    end

    it "matches list entries and clients whatever their spelling" do
      handler = throttle(whitelist: ["::ffff:8.8.8.8"], blacklist: ["2001:DB8:0:0:0:0:0:1"], trusted: ["10.0.0.1"])
      3.times { status(handler, "8.8.8.8").should eq 200 }
      status(handler, "10.0.0.1", ["[2001:db8::1]:80"]).should eq 429
    end

    it "counts a header that names no client apart from the proxy's own requests, so a health check is not blocked by it" do
      handler = throttle(trusted: ["fd00::/8", "10.0.0.1"])
      status(handler, "fd00::1", ["bogus"]).should eq 200
      status(handler, "fd00::2", ["bogus"]).should eq 429 # same /64, same unresolved bucket
      status(handler, "fd00::2").should eq 200            # no header at all: the proxy itself
      status(handler, "fd00::3", ["1.1.1.1"]).should eq 200
      status(handler, "fd00::3", ["1.1.1.1"]).should eq 429
    end

    it "lets an attacker behind the proxy fill only the unresolved bucket" do
      handler = throttle(trusted: ["10.0.0.1"], threshold: 2)
      statuses = 5.times.map { status(handler, "10.0.0.1", [(["10.0.0.1"] * 3).join(", ")]) }.to_a
      statuses.should eq [200, 200, 429, 429, 429]
      status(handler, "10.0.0.1").should eq 200
      status(handler, "10.0.0.1", ["1.1.1.1"]).should eq 200
    end

    it "does not exempt unresolved forwards when the proxy itself is whitelisted or blacklisted" do
      handler = throttle(trusted: ["10.0.0.1"], whitelist: ["10.0.0.1"])
      statuses = 4.times.map { status(handler, "10.0.0.1", ["garbage"]) }.to_a
      statuses.should eq [200, 429, 429, 429]
      3.times { status(handler, "10.0.0.1").should eq 200 } # the proxy's own requests keep their exemption
      blacklisted = throttle(trusted: ["10.0.0.1"], blacklist: ["10.0.0.1"])
      status(blacklisted, "10.0.0.1", ["garbage"]).should eq 200
    end

    it "says IPv4-mapped entries take an IPv4 prefix length" do
      expect_raises(ArgumentError, /IPv4-mapped address takes an IPv4 prefix length/) { throttle(trusted: ["::ffff:10.0.0.0/96"]) }
      expect_raises(ArgumentError, /prefix length outside 0\.\.32/) { throttle(trusted: ["10.0.0.0/96"]) }
      expect_raises(ArgumentError, /prefix length outside 0\.\.128/) { throttle(trusted: ["fd00::/129"]) }
    end

    it "does not detect two halves as a catch-all, and lists accept 0.0.0.0/0 on purpose" do
      throttle(trusted: ["0.0.0.0/1", "128.0.0.0/1"])
      handler = throttle(whitelist: ["0.0.0.0/0"])
      3.times { status(handler, "8.8.8.8").should eq 200 }
    end

    it "refuses a catch-all block, in any spelling, and still accepts a broad one" do
      ["0.0.0.0/0", "::/0", "1.2.3.4/0", "::ffff:0.0.0.0/0", " 0.0.0.0/0 "].each do |entry|
        expect_raises(ArgumentError, /every address/) { throttle(trusted: [entry]) }
      end
      throttle(trusted: ["10.0.0.0/8", "0.0.0.0/1", "::/1"])
    end

    it "reads the header lines of a request as one list" do
      handler = throttle(trusted: ["10.0.0.1"])
      status(handler, "10.0.0.1", ["9.9.9.9", "1.1.1.1"]).should eq 200
      status(handler, "10.0.0.1", ["8.8.8.8", "1.1.1.1"]).should eq 429
    end
  end

  describe "IPv6 clients" do
    it "are counted by their /64: rotating the low bits does not dodge the limit" do
      handler = throttle
      statuses = (1..4).map { |n| status(handler, "2001:db8:1:2::#{n.to_s(16)}") }
      statuses.should eq [200, 429, 429, 429]
      handler.stats[:tracked_ips].should eq 1
      status(handler, "2001:db8:1:3::1").should eq 200
      handler.stats[:tracked_ips].should eq 2
    end

    it "can be counted by another prefix length" do
      handler = throttle(ipv6_prefix: 128)
      status(handler, "2001:db8:1:2::1").should eq 200
      status(handler, "2001:db8:1:2::2").should eq 200
    end

    it "count a mapped IPv4 peer as that IPv4 address" do
      handler = throttle
      status(handler, "::ffff:1.2.3.4").should eq 200
      status(handler, "1.2.3.4").should eq 429
    end
  end

  describe "memory" do
    it "sweeps the trackers whose window ended, on a later request, without a fiber" do
      with_fake_clock do |clock|
        handler = throttle
        200.times { |n| status(handler, "20.0.#{n // 250}.#{n % 250 + 1}") }
        handler.stats[:tracked_ips].should eq 200
        clock.advance(61.seconds)
        status(handler, "30.0.0.1")
        handler.stats[:tracked_ips].should eq 1
      end
    end

    it "sweeps at most once a second" do
      with_fake_clock do |clock|
        handler = throttle
        status(handler, "20.0.0.1")
        clock.advance(61.seconds)
        status(handler, "20.0.0.2") # sweeps the first
        status(handler, "20.0.0.3")
        clock.advance(100.milliseconds)
        handler.stats[:tracked_ips].should eq 2
      end
    end

    it "keeps a blocked client until its block ends, and then drops it" do
      with_fake_clock do |clock|
        handler = throttle
        2.times { status(handler, "6.6.6.6") }
        clock.advance(30.seconds) # the window (60) has not ended, nor the block (60)
        status(handler, "7.7.7.7")
        handler.stats.should eq({tracked_ips: 2, blocked_ips: 1})
        clock.advance(61.seconds)
        status(handler, "8.8.8.8")
        handler.stats[:tracked_ips].should eq 1
      end
    end

    it "never tracks more than max_clients, a flood of addresses included" do
      handler = throttle(max_clients: 50)
      2000.times { |n| status(handler, "20.#{n // 250}.#{n % 250}.1") }
      handler.stats[:tracked_ips].should eq 50
    end

    it "evicts the oldest clients that are not blocked first" do
      handler = throttle(max_clients: 3)
      2.times { status(handler, "6.6.6.6") } # blocked, and the oldest
      status(handler, "1.0.0.1")
      status(handler, "1.0.0.2")
      status(handler, "1.0.0.3") # evicts 1.0.0.1
      handler.stats.should eq({tracked_ips: 3, blocked_ips: 1})
      status(handler, "6.6.6.6").should eq 429 # still blocked
      status(handler, "1.0.0.2").should eq 429 # kept
      status(handler, "1.0.0.1").should eq 200 # forgotten, evicts 1.0.0.3
    end

    it "evicts a blocked client only when every tracked one is blocked" do
      handler = throttle(max_clients: 2)
      %w(6.6.6.1 6.6.6.2).each { |ip| 2.times { status(handler, ip) } }
      status(handler, "6.6.6.3").should eq 200
      handler.stats[:tracked_ips].should eq 2
      status(handler, "6.6.6.1").should eq 200 # the oldest block was given up
    end
  end

  describe "over a real connection" do
    forwarded = ->(address : Socket::IPAddress, ips : Array(String)) {
      ips.map { |ip| HTTP::Client.new(address.address, address.port).get("/", HTTP::Headers{"X-Forwarded-For" => ip}).status_code }
    }

    it "lets a spoofed X-Forwarded-For from an untrusted peer neither dodge the limit nor frame a client" do
      statuses = serve([] of String) { |address| forwarded.call(address, %w(1.1.1.1 2.2.2.2 3.3.3.3)) }
      statuses.should eq [200, 429, 429]
    end

    it "reads X-Forwarded-For from a trusted proxy, from the right" do
      statuses = serve(["127.0.0.1"]) { |address| forwarded.call(address, ["1.1.1.1", "2.2.2.2", "1.1.1.1", "9.9.9.9, 2.2.2.2"]) }
      statuses.should eq [200, 200, 429, 429]
    end

    it "treats two header lines on the wire as one list" do
      statuses = serve(["127.0.0.1"]) do |address|
        socket_status = ->(lines : Array(String)) {
          socket = TCPSocket.new(address.address, address.port)
          socket << "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" << lines.map { |line| "X-Forwarded-For: #{line}\r\n" }.join << "\r\n"
          line = socket.gets.to_s
          socket.close
          line.split(' ')[1].to_i
        }
        [socket_status.call(["9.9.9.9", "1.1.1.1"]), socket_status.call(["8.8.8.8", "1.1.1.1"])]
      end
      statuses.should eq [200, 429]
    end
  end

  describe "black and white lists" do
    it "take CIDR blocks of both families, and match IPv6 clients by address" do
      handler = throttle(threshold: 100, whitelist: ["10.0.0.0/8", "2001:db8::/32"], blacklist: ["192.168.0.0/16", "fe80::1"])
      status(handler, "10.9.9.9").should eq 200
      status(handler, "2001:db8:5::1").should eq 200
      status(handler, "192.168.4.4").should eq 429
      status(handler, "fe80::1").should eq 429
      status(handler, "fe80::2").should eq 200
    end

    it "refuse an entry that is not an address or block when the handler is built" do
      ["unknown", "evil.example", "1.2.3.4:80", "10.0.0.0/33", "", "*"].each do |entry|
        expect_raises(ArgumentError, /whitelist/) { throttle(whitelist: [entry]) }
        expect_raises(ArgumentError, /blacklist/) { throttle(blacklist: [entry]) }
      end
    end
  end

  describe "a table full of blocked clients" do
    it "admits new clients in constant time, evicting the oldest unblocked one" do
      count = 50_000
      handler = Azu::Handler::Throttle.new(interval: 600, duration: 600, threshold: 1, blacklist: [] of String, whitelist: [] of String, max_clients: count + 100)
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
      count.times { |n| 2.times { status(handler, "20.#{n // 65_536}.#{(n // 256) % 256}.#{n % 256}") } }
      handler.stats.should eq({tracked_ips: count, blocked_ips: count})

      started = Time.instant
      5_000.times { |n| status(handler, "30.#{n // 65_536}.#{(n // 256) % 256}.#{n % 256}") }
      elapsed = Time.instant - started

      handler.stats[:tracked_ips].should eq count + 100
      handler.stats[:blocked_ips].should eq count
      # A scan of the blocked clients per newcomer costs 2 ms each here (10 s for the loop); O(1) takes about 20 ms.
      elapsed.should be < 2.seconds
    end

    it "gives up the block that ends first, and only that one, when every client is blocked" do
      with_fake_clock do |clock|
        handler = throttle(max_clients: 3)
        %w(1.0.0.1 1.0.0.2 1.0.0.3).each do |ip|
          2.times { status(handler, ip) }
          clock.advance(1.second) # the blocks end in this order
        end
        handler.stats.should eq({tracked_ips: 3, blocked_ips: 3})
        status(handler, "1.0.0.4").should eq 200 # admitted, and the oldest block (1.0.0.1) went
        handler.stats.should eq({tracked_ips: 3, blocked_ips: 2})
        status(handler, "1.0.0.2").should eq 429
        status(handler, "1.0.0.3").should eq 429
        status(handler, "1.0.0.1").should eq 200 # forgotten
      end
    end

    it "keeps admitting fresh self-blocking clients quickly when the whole table is blocks" do
      handler = Azu::Handler::Throttle.new(interval: 600, duration: 600, threshold: 1, blacklist: [] of String, whitelist: [] of String, max_clients: 50_000)
      handler.next = ->(context : HTTP::Server::Context) { context.response.print "OK" }
      50_000.times { |n| 2.times { status(handler, "20.#{n // 65_536}.#{(n // 256) % 256}.#{n % 256}") } }
      started = Time.instant
      2_000.times { |n| 2.times { status(handler, "30.0.#{n // 256}.#{n % 256}") } }
      (Time.instant - started).should be < 2.seconds
      handler.stats.should eq({tracked_ips: 50_000, blocked_ips: 50_000})
    end
  end
end
