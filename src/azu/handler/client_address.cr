module Azu
  module Handler
    # Addresses as handlers compare them: parsing, CIDR sets of trusted proxies, and the client of a request that came
    # through them. An address is a 128 bit number; an IPv4 address (or an IPv4-mapped IPv6 one, `::ffff:1.2.3.4`) is the
    # same number, so both spellings are one client.
    module ClientAddress
      V4_PREFIX = 0xffff_0000_0000_u128

      # The longest `X-Forwarded-For` chain looked at (hops from the right); a longer one is not believed.
      MAX_HOPS = 32

      # Parses an address the way a proxy writes it in `X-Forwarded-For`: `1.2.3.4`, `1.2.3.4:5678`, `::1`, `[::1]`,
      # `[::1]:5678`, `::ffff:1.2.3.4`. Anything else (a name, `unknown`, `_hidden`, a zone id, a port out of range,
      # an octet with a leading zero, whitespace inside) is nil.
      def self.parse(text : String) : UInt128?
        text = text.strip(" \t")
        return if text.empty? || text.bytesize > 64 || !text.ascii_only?

        if text.starts_with?('[')
          parse_bracketed(text)
        elsif text.count(':') == 1
          host, _, port = text.partition(':')
          valid_port?(port) ? parse_v4(host) : nil
        elsif text.includes?(':')
          parse_v6(text)
        else
          parse_v4(text)
        end
      end

      private def self.parse_bracketed(text : String) : UInt128?
        close = text.index(']') || return
        port = text[(close + 1)..]
        return unless port.empty? || valid_port?(port.lchop?(':'))
        parse_v6(text[1...close])
      end

      # The peer address of a connection: `Socket::IPAddress` or nil.
      def self.of(address : Socket::Address?) : UInt128?
        address.as?(Socket::IPAddress).try { |ip| parse(ip.address) }
      end

      def self.ipv4?(address : UInt128) : Bool
        (address >> 32) == 0xffff_u128
      end

      # Dotted for IPv4, the full lower-case form for IPv6.
      def self.to_s(address : UInt128) : String
        if ipv4?(address)
          (0..3).map { |index| ((address >> (24 - 8 * index)) & 0xff).to_s }.join('.')
        else
          (0..7).map { |index| ((address >> (112 - 16 * index)) & 0xffff).to_s(16) }.join(':')
        end
      end

      # The key a client is counted under: its IPv4 address, or its IPv6 network (the first *prefix* bits), since one
      # subscriber holds a whole /64 and can change the rest at will.
      def self.key(address : UInt128, prefix : Int32 = 64) : String
        return to_s(address) if ipv4?(address)
        "#{to_s(address & mask(prefix))}/#{prefix}"
      end

      # A set of addresses and CIDR blocks (`10.0.0.0/8`, `fd00::/8`, `203.0.113.7`, `::1`).
      class Networks
        record Block, base : UInt128, bits : Int32 do
          def includes?(address : UInt128) : Bool
            (address & ClientAddress.mask(bits)) == base
          end
        end

        getter blocks : Array(Block)

        def self.parse(entries : Array(String)) : Networks
          new(entries.map { |entry| block(entry) })
        end

        private def self.block(entry : String) : Block
          address_text, slash, length = entry.strip.partition('/')
          address = ClientAddress.parse(address_text)
          if address.nil? || address_text.includes?('[') || address_text.count(':') == 1
            raise ArgumentError.new("trusted_proxies: #{entry.inspect} is not an IP address or CIDR block")
          end
          v4 = ClientAddress.ipv4?(address)
          bits = slash.empty? ? (v4 ? 32 : 128) : length.to_i?(whitespace: false) || -1
          max = v4 ? 32 : 128
          raise ArgumentError.new("trusted_proxies: #{entry.inspect} has a prefix length outside 0..#{max}") unless 0 <= bits <= max
          bits += 96 if v4
          Block.new(address & ClientAddress.mask(bits), bits)
        end

        def initialize(@blocks : Array(Block))
        end

        def empty? : Bool
          @blocks.empty?
        end

        def includes?(address : UInt128) : Bool
          @blocks.any?(&.includes?(address))
        end
      end

      # The client of a request that reached us from *peer*. When *peer* is not a trusted proxy, or no proxy is trusted,
      # it is the peer: `X-Forwarded-For` is a header the sender chose. When it is, the hops of the header (every
      # line, in order) are read from the right, past the trusted proxies, and the first address that is not trusted is
      # the client: a proxy appends the address it saw, so only the right-most entries can be believed; the
      # left-most are whatever the client wrote. An unreadable hop, a chain with nothing but trusted hops and a
      # chain longer than MAX_HOPS all give back the peer.
      def self.client(peer : UInt128, forwarded_for : Array(String)?, trusted : Networks) : UInt128
        return peer if trusted.empty? || !trusted.includes?(peer) || forwarded_for.nil?

        hops = forwarded_for.flat_map(&.split(','))
        return peer if hops.size > MAX_HOPS * 4
        hops.reverse_each.first(MAX_HOPS).each do |hop|
          address = parse(hop) || return peer
          return address unless trusted.includes?(address)
        end
        peer
      end

      # :nodoc:
      def self.mask(bits : Int32) : UInt128
        return 0_u128 if bits <= 0
        return UInt128::MAX if bits >= 128
        UInt128::MAX << (128 - bits)
      end

      private def self.valid_port?(port : String?) : Bool
        return false if port.nil? || port.empty? || port.size > 5
        port.each_char.all?(&.ascii_number?) && port.to_i <= 65535
      end

      private def self.parse_v4(text : String) : UInt128?
        octets = text.split('.', remove_empty: false)
        return unless octets.size == 4
        value = 0_u128
        octets.each do |octet|
          return if octet.empty? || octet.size > 3 || !octet.each_char.all?(&.ascii_number?) || (octet.size > 1 && octet.starts_with?('0'))
          number = octet.to_i
          return if number > 255
          value = (value << 8) | number
        end
        V4_PREFIX | value
      end

      private def self.parse_v6(text : String) : UInt128?
        return if text.empty? || text.includes?('%')
        head, double, tail = text.partition("::")
        return if tail.includes?("::")
        front = groups(head, double.empty?) || return
        back = groups(tail, true) || return
        if double.empty?
          return unless front.size == 8
          words = front
        else
          return unless front.size + back.size <= 7
          words = front + Array.new(8 - front.size - back.size, 0_u16) + back
        end
        words.reduce(0_u128) { |value, word| (value << 16) | word }
      end

      # The 16 bit groups of one side of a `::`; the last one of the address (*last*) may be a dotted IPv4 address, which is two groups.
      private def self.groups(text : String, last : Bool) : Array(UInt16)?
        return [] of UInt16 if text.empty?
        parts = text.split(':', remove_empty: false)
        result = [] of UInt16
        parts.each_with_index do |part, index|
          if part.includes?('.')
            return unless last && index == parts.size - 1
            v4 = parse_v4(part) || return
            result << ((v4 >> 16) & 0xffff).to_u16 << (v4 & 0xffff).to_u16
          else
            return if part.empty? || part.size > 4 || !part.each_char.all?(&.hex?)
            result << part.to_u16(16)
          end
        end
        result
      end
    end
  end
end
