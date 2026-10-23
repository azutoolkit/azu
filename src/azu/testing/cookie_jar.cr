module Azu
  module Testing
    # The cookies a `Client` keeps between requests, the way a browser does: the ones a response sets
    # are sent back with later requests, until they expire (by `Azu::Clock`, so a fake clock expires them)
    # or the server deletes them. Domains and `Secure` are not modelled; paths are.
    class CookieJar
      private record Entry, cookie : HTTP::Cookie, expires_at : Time?

      def initialize
        @entries = {} of String => Entry
      end

      # Stores the `Set-Cookie` headers of a response; an expired cookie removes the one of that name.
      def absorb(headers : HTTP::Headers) : Nil
        HTTP::Cookies.from_server_headers(headers).each do |cookie|
          expires_at = expiry(cookie)
          if expires_at && expires_at <= Clock.now
            @entries.delete(cookie.name)
          else
            @entries[cookie.name] = Entry.new(cookie, expires_at)
          end
        end
      end

      def []=(name : String, value : String) : String
        @entries[name] = Entry.new(HTTP::Cookie.new(name, value, path: "/"), nil)
        value
      end

      def []?(name : String) : String?
        live[name]?.try(&.cookie.value)
      end

      def [](name : String) : String
        self[name]? || raise KeyError.new("no cookie named #{name.inspect}")
      end

      def delete(name : String) : Nil
        @entries.delete(name)
      end

      def clear : Nil
        @entries.clear
      end

      def to_h : Hash(String, String)
        live.transform_values(&.cookie.value)
      end

      # The `Cookie` request header for *path*; nil when no cookie applies.
      def header_for(path : String) : String?
        pairs = live.values.select { |entry| path.starts_with?(entry.cookie.path || "/") }
        pairs.map { |entry| "#{entry.cookie.name}=#{entry.cookie.value}" }.join("; ").presence
      end

      private def live : Hash(String, Entry)
        now = Clock.now
        @entries.reject! { |_, entry| (expiry = entry.expires_at) && expiry <= now }
        @entries
      end

      private def expiry(cookie : HTTP::Cookie) : Time?
        if max_age = cookie.max_age
          Clock.now + max_age
        else
          cookie.expires
        end
      end
    end
  end
end
