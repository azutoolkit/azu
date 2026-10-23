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
      pattern = pattern?(name) || raise ArgumentError.new(
        "Unknown route :#{name}. Known routes: #{known.map { |n| ":#{n}" }.join(", ")}. " \
        "Register one with `get \"/path\", as: :#{name}`."
      )
      expand(pattern, **params)
    end

    # Names of every registered route.
    def self.known : Array(String)
      @@mutex.synchronize { @@named.keys }
    end

    # Replaces each `:key` in *pattern* with the URL-encoded value.
    # Longer keys are replaced first so `:id` never clobbers `:identifier`.
    def self.expand(pattern : String, **params) : String
      pairs = [] of Tuple(String, String)
      params.each { |key, value| pairs << {key.to_s, value.to_s} }
      pairs.sort_by! { |pair| -pair[0].size }

      url = pattern
      pairs.each do |pair|
        url = url.gsub(Regex.new(":#{Regex.escape(pair[0])}(?![A-Za-z0-9_])"), URI.encode_path_segment(pair[1]))
      end
      url
    end

    # Forgets every named route. Intended for specs.
    def self.clear : Nil
      @@mutex.synchronize { @@named.clear }
    end
  end
end
