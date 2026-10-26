class Azu::Templates
  # Turns the templates below `dir` (from the project root, as with ECR) into a `CompiledSet` at build time. `strict`
  # fails the build for a template that would fall back to Crinja.
  macro compile(dir, strict = false)
    {% if strict %}{{ run("../template_compiler/process", dir, "--strict") }}{% else %}{{ run("../template_compiler/process", dir) }}{% end %}
  end

  # name => {source, render proc}; name => why it falls back to Crinja
  record CompiledSet, templates : Hash(String, {String, Proc(IO, Crinja, Nil)}), fallbacks : Hash(String, String)

  # Renders with its compiled proc. Immutable and shared: a render's state is in the fiber's `env.context`. It keeps
  # Crinja's parsed nodes too: a Crinja template that extends it renders the parent's nodes, not its `render`.
  class CompiledTemplate < Crinja::Template
    def initialize(source : String, @body : Proc(IO, Crinja, Nil), env : Crinja, name : String, filename : String)
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

    def render(io : IO, env : Crinja)
      env.context.autoescape = env.config.autoescape?(filename) # as Crinja's renderer does
      @body.call(io, env)
    rescue e : Crinja::Error
      e.template ||= self
      raise e
    end
  end
end
