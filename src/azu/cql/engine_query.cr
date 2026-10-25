module Azu
  module CQL
    # The query string of a database URL, edited without re-encoding what it keeps: every pair that is not
    # removed, renamed or appended stays byte for byte as written (`%20` stays `%20`, `+` stays `+`, order,
    # duplicates and key case are unchanged). Keys are compared case-sensitively after percent-decoding.
    class EngineQuery
      def initialize(query : String)
        @pairs = query.split('&', remove_empty: true)
      end

      def has?(key : String) : Bool
        @pairs.any? { |pair| key_of(pair) == key }
      end

      # The percent-decoded value of the first pair with this key ("" for `key` or `key=`), nil when absent.
      def value(key : String) : String?
        @pairs.find { |pair| key_of(pair) == key }.try { |pair| URI.decode(pair.partition('=')[2]) }
      end

      def delete(key : String) : Nil
        @pairs.reject! { |pair| key_of(pair) == key }
      end

      # Renames the key of every pair called `from`, or drops them when `to` is already set.
      def rename(from : String, to : String) : Nil
        return delete(from) if has?(to)
        @pairs.map! { |pair| key_of(pair) == from ? "#{to}#{pair.partition('=')[1]}#{pair.partition('=')[2]}" : pair }
      end

      def add(key : String, value : String) : Nil
        @pairs << "#{key}=#{value}" unless has?(key)
      end

      def replace_value(key : String, value : String) : Nil
        @pairs.map! { |pair| key_of(pair) == key ? "#{pair.partition('=')[0]}=#{value}" : pair }
      end

      def empty? : Bool
        @pairs.empty?
      end

      def to_s(io : IO) : Nil
        io << @pairs.join('&')
      end

      private def key_of(pair : String) : String
        URI.decode(pair.partition('=')[0])
      end
    end
  end
end
