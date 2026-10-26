# Every reopening of Crinja that Azu makes lives in this file. They target Crinja 0.9.0, which shard.yml pins
# (`~> 0.9.0`): check each one against Crinja's source before moving the pin.

class Fiber
  # :nodoc:
  # The Crinja contexts this fiber is rendering in, innermost last, each with its environment (see `Crinja#context`).
  property crinja_scopes : Array({Crinja, Crinja::Context})?
end

class Crinja
  # Crinja keeps the context of the render in progress on the environment, which every request shares: two renders
  # that overlap (a helper that yields the fiber, threads under preview_mt) read each other's variables, and one that
  # ends out of order leaves its context behind for every later render. Each fiber keeps its own instead, per
  # environment; outside a render a fiber sees the environment's global context.
  def context : Context
    if scopes = Fiber.current.crinja_scopes
      (scopes.size - 1).downto(0) do |index|
        env, current = scopes.unsafe_fetch(index)
        return current if env.same?(self)
      end
    end
    global_context
  end

  # Makes `ctx` this fiber's context in this environment while the block runs.
  def with_scope(ctx : Context, &)
    scopes = Fiber.current.crinja_scopes ||= [] of {Crinja, Context}
    scopes << {self, ctx}
    begin
      yield ctx
    ensure
      scopes.pop
    end
  end

  # As in Crinja, with autoescape set on this fiber's context rather than on the environment's.
  def evaluate(expression, bindings = nil) : String
    parsed = Parser::ExpressionParser.new(Parser::ExpressionLexer.new(config, expression)).parse
    context.autoescape = config.autoescape?
    stringify(evaluate(parsed, bindings))
  end
end

class Crinja::Template
  # A macro belongs to the render that defines it, not to the template every render shares (Crinja also kept it in
  # `#macros`): one request's macro, and the defaults it evaluated, would reach the next request that imports it.
  def register_macro(name, instance)
    env.context.macros[name] = instance
  end

  # A render never runs in the global context itself (`include ... without context` asks for it): a `set` there
  # would outlive the render and reach every later one.
  def render(io : IO, bindings : Context)
    scope = bindings.same?(env.global_context) ? Context.new(bindings) : bindings
    env.with_scope(scope) { render(io, env) }
  end

  # :nodoc:
  # Renders this template for `{% from %}` or `{% import %}` in a context of its own and returns it: it holds what
  # the import defined. A child of the importer's context, so the import sees the importer's variables with or without
  # context, as in Crinja. Its macros and top-level variables are then copied into the importer's context, where
  # Crinja put them (it rendered the import there), so an imported macro reaches its file's other macros and
  # variables when it is called; that context belongs to one render. The import's autoescape stays its own.
  # A file that imports itself, directly or through others, raises `Context::TagCycleException`; one file imported
  # twice by the same page does not.
  def render_for_import : Context
    importer = env.context
    importer.import_path_stack << name
    scope = Context.new(importer)
    begin
      render(scope)
    ensure
      importer.import_path_stack.pop
    end
    importer.macros.merge!(scope.macros)
    scope.scope.each { |key, value| importer[key] = value }
    scope
  end
end

# `{% from %}` and `{% import %}` read the macros of the import's own render (see `Template#render_for_import`).
class Crinja::Tag::From
  private def interpret(io : IO, renderer : Renderer, tag_node : TagNode)
    env = renderer.env
    source_expression, _, imports = Parser.new(tag_node.arguments, env.config).parse_from_tag
    template = env.get_template(env.evaluate(source_expression).to_s)
    scope = template.render_for_import

    imports.each do |from_name, import_name|
      if makro = scope.macros[from_name]?
        env.context.macros[import_name] = makro
      elsif scope.has_key?(from_name)
        env.context[import_name] = scope[from_name]
      else
        raise RuntimeError.new("Unknown import `#{from_name}` in #{template}").at(tag_node)
      end
    end
  end
end

class Crinja::Tag::Import
  private def interpret(io : IO, renderer : Renderer, tag_node : TagNode)
    env = renderer.env
    parser = ArgumentsParser.new(tag_node.arguments, env.config)
    name_expr = parser.parse_expression
    context_var = parser.if_identifier("as") { parser.next_token; parser.current_token.value }
    parser.close
    template = env.get_template(env.evaluate(name_expr).to_s)

    scope = template.render_for_import
    scope.macros.each { |key, value| env.context.macros["#{context_var}.#{key}"] = value } if context_var
  end
end

abstract class Crinja::FeatureLibrary(T)
  # :nodoc:
  # Counts the stores: a compiled template resolves its filters once, and again when this (or `aliases` or `disabled`)
  # changes.
  getter revision : Int32 = 0

  def []=(name, obj : T)
    @revision &+= 1
    previous_def
  end
end

# Crinja's `autoescape?(filename)` with the filename's part computed once per compiled template (`extension`), so a
# compiled render reads the rule (changed in place or not) without allocating. Crinja's 1-arg `autoescape?` is
# untouched; `CompiledTemplate` takes this path only for Crinja's own `Config` and `Autoescape` classes. It assumes
# `match_extension?` is Crinja's own (`extension` is its extension part, `extension(f) == e` exactly when
# `match_extension?([e], f)`): an app that reopens `match_extension?` must reopen `extension` the same way.
class Crinja::Config::Autoescape
  # :nodoc:
  # The extension `match_extension?` matches the lists against (`"html"` for `page.html.j2`), or nil when it has none.
  def self.extension(filename : String) : String?
    filename = filename.downcase
    extname = File.extname(filename)
    extname = File.extname(filename[0..(-extname.size - 1)]) if {".jinja", ".j2"}.includes?(extname)
    extname[1..] unless extname.empty?
  end

  # :nodoc:
  # `autoescape?(filename)` for `extension == Autoescape.extension(filename)`.
  def autoescape?(filename : String?, extension : String?) : Bool
    if filename.nil? || filename.empty?
      default_for_string
    elsif extension && enabled_extensions.includes?(extension)
      true
    elsif extension && disabled_extensions.includes?(extension)
      false
    else
      default
    end
  end
end
