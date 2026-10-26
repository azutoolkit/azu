module Azu
  module Testing
    # The cookies a `Client` keeps between requests, the way a browser does: the ones a response sets
    # are sent back with later requests, until they expire (by `Azu::Clock`, so a fake clock expires them)
    # or the server deletes them. Domains and `Secure` are not modelled; paths are, as RFC 6265 has them:
    # a cookie set without a `Path` belongs to the directory of the request that set it (`GET /auth/login`
    # sets it for `/auth`), and a name holds one cookie per path.
    class CookieJar
      private record Entry, cookie : HTTP::Cookie, path : String, expires_at : Time?

      # *now* tells the time; a client passes its own clock so the jar ages with it outside requests too.
      def initialize(@now : Proc(Time) = -> { Clock.now })
        @entries = {} of {String, String} => Entry
      end

      # Stores the `Set-Cookie` headers of a response to a request for *path*; an expired cookie removes the
      # one of that name and path.
      def absorb(headers : HTTP::Headers, path : String = "/") : Nil
        return unless lines = headers.get?("Set-Cookie")
        lines.each do |line|
          # One header at a time: `HTTP::Cookies` keeps one cookie per name, a response may set one per path.
          HTTP::Cookies.from_server_headers(HTTP::Headers{"Set-Cookie" => line}).each { |cookie| store(cookie, path) }
        end
      end

      # Sets a cookie for every path, as `Path=/` does.
      def []=(name : String, value : String) : String
        store(HTTP::Cookie.new(name, value, path: "/"), "/")
        value
      end

      # The value of the cookie *name*; of several paths, the shortest one's (see `#to_h`).
      def []?(name : String) : String?
        to_h[name]?
      end

      def [](name : String) : String
        self[name]? || raise KeyError.new("no cookie named #{name.inspect}")
      end

      # Removes the cookies of *name*, whatever their path.
      def delete(name : String) : Nil
        @entries.reject! { |(cookie_name, _), _| cookie_name == name }
      end

      def clear : Nil
        @entries.clear
      end

      # Name => value. A name held for several paths gives the shortest path's value: a request that carries them
      # all lists it last, and that is the one `HTTP::Cookies` (so the app) reads.
      def to_h : Hash(String, String)
        ordered(live.values).each_with_object({} of String => String) do |entry, values|
          values[entry.cookie.name] = entry.cookie.value
        end
      end

      # The `Cookie` request header for *path*; nil when no cookie applies.
      def header_for(path : String) : String?
        ordered(live.values.select { |entry| path_matches?(entry.path, path) })
          .join("; ") { |entry| "#{entry.cookie.name}=#{entry.cookie.value}" }
          .presence
      end

      private def store(cookie : HTTP::Cookie, request_path : String) : Nil
        path = cookie.path.try { |value| value if value.starts_with?('/') } || default_path(request_path)
        key = {cookie.name, path}
        expires_at = expiry(cookie)
        if expires_at && expires_at <= @now.call
          @entries.delete(key)
        else
          @entries[key] = Entry.new(cookie, path, expires_at)
        end
      end

      # RFC 6265 section 5.1.4: the request path up to its last `/`, or `/` when that is the only one.
      private def default_path(request_path : String) : String
        return "/" unless request_path.starts_with?('/')
        slash = request_path.rindex('/') || 0
        slash.zero? ? "/" : request_path[0, slash]
      end

      # RFC 6265 section 5.1.4: a cookie of `/admin` goes to `/admin` and `/admin/x`, not to `/administrator`.
      private def path_matches?(cookie_path : String, path : String) : Bool
        return true if path == cookie_path
        path.starts_with?(cookie_path) && (cookie_path.ends_with?('/') || path[cookie_path.size]? == '/')
      end

      # The order a browser sends cookies in (RFC 6265 section 5.4): longer paths first, then older ones. The hash
      # keeps insertion order, and a replaced cookie keeps its place, as it keeps its creation time in a browser.
      private def ordered(entries : Array(Entry)) : Array(Entry)
        entries.each_with_index.to_a.sort_by! { |(entry, index)| {-entry.path.size, index} }.map(&.[0])
      end

      private def live : Hash({String, String}, Entry)
        now = @now.call
        @entries.reject! { |_, entry| (expiry = entry.expires_at) && expiry <= now }
        @entries
      end

      private def expiry(cookie : HTTP::Cookie) : Time?
        if max_age = cookie.max_age
          @now.call + max_age
        else
          cookie.expires
        end
      end
    end
  end
end
