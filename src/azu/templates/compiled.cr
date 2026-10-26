class Azu::Templates
  # Turns the templates below `dir` (from the project root, as with ECR) into a `CompiledSet` at build time. `strict`
  # fails the build for a template that would fall back to Crinja.
  macro compile(dir, strict = false)
    {{ run("../template_compiler/process", dir, strict ? "--strict" : "--lenient") }}
  end

  # name => {source, the filters it calls, render proc}; name => why it falls back to Crinja
  record CompiledSet, templates : Hash(String, {String, Array(String), CompiledTemplate::Body}), fallbacks : Hash(String, String)

  # Renders with its compiled proc. Immutable and shared: a render's state is in the fiber's `env.context`. It keeps
  # Crinja's parsed nodes too: a Crinja template that extends it renders the parent's nodes, not its `render`.
  class CompiledTemplate < Crinja::Template
    # Renders to `io`, calling the template's `n`th filter as `filters[n]`; `own[n]` when that filter is one of
    # `CONTEXT_FREE`, so a loop calling it may skip the scope.
    alias Body = Proc(IO, Crinja, Array(Crinja::Callable?), Array(Bool), Nil)

    # Crinja's own filters that read nothing of `env.context` (`map`, `select`, ... call other filters or tests;
    # `join` and `string` read only the autoescape flag, which a loop scope inherits).
    CONTEXT_FREE_NAMES = %w[list batch slice first last length reverse sum random groupby escape forceescape safe urlize
      urlencode tojson xmlattr join prepend append date abs float int filesizeformat round dictsort sort upper lower
      capitalize center striptags format indent string title truncate wordcount replace trim wordwrap default attr pprint]

    # Each the first registration of its name in `Library.defaults`: Crinja's, as any other `Crinja.filter(:name)`
    # needs Crinja required first, so neither require order nor when this initialises lets another one in.
    CONTEXT_FREE = CONTEXT_FREE_NAMES.each_with_object([] of Crinja::Callable) do |name, set|
      Crinja::Filter::Library.defaults.find { |filter| filter.as?(Crinja::Callable::Instance).try(&.name) == name }.try { |own| set << own }
    end

    # Crinja's own `escape` (`e` is its alias) and `safe`: a print of either is written straight to the io.
    ESCAPE = CONTEXT_FREE.find { |filter| filter.as(Crinja::Callable::Instance).name == "escape" } || raise "no escape filter"
    SAFE   = CONTEXT_FREE.find { |filter| filter.as(Crinja::Callable::Instance).name == "safe" } || raise "no safe filter"

    # What renders share, built on the first and again when what it was built from changes: each filter (nil when
    # unknown or disabled: the call asks `env.filters`, which raises). `disabled` and `aliases` are copies, compared
    # by value on every render, so an in-place change is seen.
    private class State
      getter env : Crinja, revision : Int32, aliases : Hash(String, String), disabled : Array(String)
      getter filters : Array(Crinja::Callable?), own : Array(Bool)

      def initialize(@env, @revision, @aliases, @disabled, @filters)
        @own = filters.map { |filter| CONTEXT_FREE.any?(&.same?(filter)) }
      end

      def current?(env : Crinja, library) : Bool
        @env.same?(env) && @revision == library.revision && @disabled == library.disabled && @aliases == library.aliases
      end
    end

    @state = Atomic(State?).new(nil)

    def initialize(source : String, @filter_names : Array(String), @body : Body, env : Crinja, name : String, filename : String)
      super(source, env, name, filename)
      @extension = Crinja::Config::Autoescape.extension(filename)
    end

    # `a.b` (`key` is the member name) and `a[key]`, as `Crinja::Evaluator` resolves them; the block names `a`.
    def self.attribute(object : Crinja::Value, key, index : Bool, &) : Crinja::Value
      raise Crinja::UndefinedError.new(yield) if object.undefined?
      begin
        value = Crinja::Resolver.resolve_attribute(key, object)
      rescue Crinja::UndefinedError
        raise Crinja::UndefinedError.new(index ? "#{yield}[#{key}]" : "#{yield}.#{key}")
      end
      value.as_undefined.name = (index ? "#{yield}[#{key}]" : "#{yield}.#{key}") if value.undefined?
      value
    end

    # `Crinja::Finalizer.stringify(io, value, escape)`, writing an escaped String without building it. Invalid UTF-8
    # takes Crinja's path: its `HTML.escape(String)` replaces bad bytes with U+FFFD, the io overload copies them.
    def self.print(io : IO, value : Crinja::Value, escape : Bool) : Nil
      raw = value.raw
      return HTML.escape(raw, io) if escape && raw.is_a?(String) && raw.valid_encoding?
      Crinja::Finalizer.stringify(io, value, escape)
    end

    # Prints what Crinja's `escape` (`safe` when `escape` is false) returns for `value`: a SafeString as it is.
    def self.print_filtered(io : IO, value : Crinja::Value, escape : Bool) : Nil
      raw = value.raw
      if raw.is_a?(Crinja::SafeString)
        raw.to_s(io)
      elsif !escape
        io << value.to_s
      else
        string = raw.is_a?(String) ? raw : raw.to_s
        string.valid_encoding? ? HTML.escape(string, io) : io << HTML.escape(string) # bad bytes as Crinja: U+FFFD
      end
    end

    # The items `Crinja::Tag::For::ForLoop` yields for `collection` (and its errors), without it for an array. It
    # assumes the array does not change during the loop (ForLoop reads one item ahead, a direct walk does not).
    def self.each(collection : Crinja::Value, & : Crinja::Value ->) : Nil
      if (raw = collection.raw).is_a?(Array(Crinja::Value))
        raw.each { |item| yield item }
      else
        Crinja::Tag::For::ForLoop.new(collection).each { |item| yield item }
      end
    end

    # `Crinja::Context#unpack` of `item` into `size` (2 or more) variables, with its errors.
    def self.unpack(size : Int32, item : Crinja::Value) : Array(Crinja::Value)
      raise Crinja::RuntimeError.new("cannot unpack multiple values of type #{item.class}") unless item.iterable?
      values = item.each
      Array.new(size) { values.next.as?(Crinja::Value) || raise Crinja::RuntimeError.new("Missing value for unpack") }
    end

    # Unlike Crinja, which renders to a buffer first, it writes to `io` as it goes: on an error `io` holds the output
    # so far. Azu's own render paths go through a `String`, so they are unaffected.
    def render(io : IO, env : Crinja)
      state = state(env)
      env.context.autoescape = autoescape?(env.config) # as Crinja's renderer does, on every render
      @body.call(io, env, state.filters, state.own)
    rescue e : Crinja::Error
      e.template ||= self
      raise e
    end

    # Crinja's renderer asks `env.config.autoescape?(filename)`. For Crinja's own classes the precomputed extension
    # gives the same answer without allocating; an app's subclass of either (or of the rule) is asked as Crinja asks.
    private def autoescape?(config : Crinja::Config) : Bool
      rule = config.autoescape
      if config.class == Crinja::Config && rule.class == Crinja::Config::Autoescape
        rule.autoescape?(filename, @extension)
      else
        config.autoescape?(filename)
      end
    end

    # Immutable, published with one atomic pointer store: a render racing a rebuild uses either state.
    private def state(env : Crinja) : State
      library = env.filters
      state = @state.get
      return state if state && state.current?(env, library)
      state = State.new(env, library.revision, library.aliases.dup, library.disabled.dup,
        @filter_names.map { |name| library[name] rescue nil })
      @state.set(state)
      state
    end
  end
end
