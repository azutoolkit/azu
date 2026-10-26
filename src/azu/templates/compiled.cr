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

    # Crinja's own filters, shared by every environment, but those that read `env.context`: through other filters or
    # tests (`map`, `select`, ...) or for the autoescape flag (`join`, `string`).
    CONTEXT_FREE = Crinja::Filter::Library.new.try { |library| (library.keys - %w[map select reject selectattr rejectattr join string]).map { |name| library[name] } }

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
      env.context.autoescape = env.config.autoescape?(filename) # as Crinja's renderer does, on every render
      @body.call(io, env, state.filters, state.own)
    rescue e : Crinja::Error
      e.template ||= self
      raise e
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
