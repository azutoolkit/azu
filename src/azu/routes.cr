require "uri"

module Azu
  # Registry of named routes, filled by `get "/users/:id", as: :user`.
  #
  # ```
  # get "/users/:id", as: :user
  #
  # Azu::Routes.path(:user, id: 42) # => "/users/42"
  # ```
  #
  # Inside an `Azu::Endpoint`, `url_for(:user, id: 42)` does the same, and
  # templates can call `{{ url_for("user", id=42) }}`.
  module Routes
    @@named = {} of String => String
    @@mutex = Mutex.new

    # Remembers *path* under *name* (a Symbol or String). Re-registering a name replaces the old path.
    def self.register(name : Symbol | String, path : String) : Nil
      @@mutex.synchronize { @@named[name.to_s] = path }
    end

    # Returns the path pattern registered under *name*, or `nil`.
    def self.pattern?(name : Symbol | String) : String?
      @@mutex.synchronize { @@named[name.to_s]? }
    end

    # Expands the `:placeholders` of the route *name* with *params*.
    #
    # Raises `ArgumentError` naming the known routes when *name* is unknown, so a
    # typo is easy to spot.
    def self.path(name : Symbol | String, **params) : String
      expand(pattern?(name) || raise(unknown(name)), **params)
    end

    private def self.unknown(name : Symbol | String) : ArgumentError
      ArgumentError.new(
        "Unknown route :#{name}. Known routes: #{known.map { |n| ":#{n}" }.join(", ")}. " \
        "Register one with `get \"/path\", as: :#{name}`."
      )
    end

    # Names of every registered route.
    def self.known : Array(String)
      @@mutex.synchronize { @@named.keys }
    end

    # Replaces each `:key` in *pattern* with the URL-encoded value.
    # Longer keys are replaced first so `:id` never clobbers `:identifier`.
    def self.expand(pattern : String, **params) : String
      values = Hash(String, String).new
      params.each { |key, value| values[key.to_s] = value.to_s }
      expand(pattern, values)
    end

    # Same as above for params only known at run time (e.g. from a template).
    def self.expand(pattern : String, params : Hash(String, String)) : String
      pairs = params.to_a
      pairs.sort_by! { |pair| -pair[0].size }

      url = pattern
      pairs.each do |pair|
        url = url.gsub(Regex.new(":#{Regex.escape(pair[0])}(?![A-Za-z0-9_])"), URI.encode_path_segment(pair[1]))
      end
      url
    end

    # Looks the route up by name and expands it with run-time *params*.
    def self.path(name : Symbol | String, params : Hash(String, String)) : String
      expand(pattern?(name) || raise(unknown(name)), params)
    end

    # Forgets every named route. Intended for specs.
    def self.clear : Nil
      @@mutex.synchronize { @@named.clear }
    end
  end
end
