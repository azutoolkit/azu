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
    # Renders to `io`, calling the template's `n`th filter as `filters[n]`.
    alias Body = Proc(IO, Crinja, Array(Crinja::Callable?), Nil)

    # What renders share, built on the first and again when what it was built from changes: the autoescape flag of
    # the file name and each filter (nil when unknown or disabled: the call asks `env.filters`, which raises).
    private record State, env : Crinja, stamp : {Int32, Int32, Int32}, rule : Crinja::Config::Autoescape, autoescape : Bool, filters : Array(Crinja::Callable?)

    @state : State?

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

    # Unlike Crinja, which renders to a buffer first, it writes to `io` as it goes: on an error `io` holds the output
    # so far. Azu's own render paths go through a `String`, so they are unaffected.
    def render(io : IO, env : Crinja)
      state = state(env)
      env.context.autoescape = state.autoescape # as Crinja's renderer does
      @body.call(io, env, state.filters)
    rescue e : Crinja::Error
      e.template ||= self
      raise e
    end

    # Immutable, published with one assignment: a render racing a rebuild uses either state.
    private def state(env : Crinja) : State
      filters, rule = env.filters, env.config.autoescape
      stamp = {filters.revision, filters.aliases.size, filters.disabled.size}
      state = @state
      return state if state && state.env.same?(env) && state.stamp == stamp && state.rule.same?(rule)
      @state = State.new(env, stamp, rule, rule.autoescape?(filename), @filter_names.map { |name| filters[name] rescue nil })
    end
  end
end
