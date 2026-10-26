require "crinja"

module Azu::TemplateCompiler
  # A template directory that is missing, or (strict mode) a template that cannot be compiled.
  class Error < Exception
  end

  # Why `emit` cannot compile a source: `line:column: construct`.
  private record Unsupported, reason : String

  # Globbed from inside `dir`, so a `[` in its name is no pattern. A template that cannot be compiled falls back to
  # Crinja at runtime and is listed in `fallbacks`; `strict` raises naming them all, in sorted order.
  def self.generate(dir : String, strict : Bool = false) : String
    raise Error.new("Azu::Templates.compile: no template directory #{dir} (the path is relative to the project root)") unless Dir.exists?(dir)
    fallbacks = {} of String => String
    entries = Dir.cd(dir) { Dir.glob("**/*.{html,jinja,j2}").sort! }.compact_map do |name|
      source = File.read(File.join(dir, name))
      case body = emit(source)
      in String
        proc = "->(io : ::IO, env : ::Crinja, filters : ::Array(::Crinja::Callable?), own : ::Array(::Bool)) { #{body}nil }"
        proc = "->{ #{@@hoisted}#{proc} }.call" unless @@hoisted.empty?
        "#{name.inspect} => {#{source.inspect}, (#{@@filters.inspect} of ::String), #{proc}}"
      in Unsupported
        fallbacks[name] = "#{name}:#{body.reason}"
        nil
      end
    end
    raise Error.new("Azu::Templates.compile: cannot compile #{fallbacks.values.join("\n")}") if strict && fallbacks.present?
    "::Azu::Templates::CompiledSet.new({#{entries.join(", ")}} of ::String => {::String, ::Array(::String), ::Azu::Templates::CompiledTemplate::Body}, " \
    "#{fallbacks.inspect} of ::String => ::String)"
  end

  # Raised while emitting, for a node `emit` cannot compile.
  private class Fallback < Exception
    getter at : Crinja::Parser::StreamPosition?

    def initialize(@at, what : String)
      super(what)
    end
  end

  # `Crinja::Tag::For`'s own argument parse: a plain loop's item variables and collection, or what it has besides.
  # It relies on Crinja's private `parse_identifier_list`, which the `~> 0.9.0` pin keeps.
  private class ForParser < Crinja::Tag::ArgumentsParser
    def parse_for : {Array(String), Crinja::AST::ExpressionNode} | String
      vars = parse_identifier_list.map(&.name)
      expect Kind::IDENTIFIER, "in"
      collection = parse_expression
      return "for ... #{current_token.value}" unless current_token.kind.eof? # `if` or `recursive`
      vars.includes?(Crinja::Tag::For::LOOP_VARIABLE) ? "for loop" : {vars, collection}
    end
  end

  # Code rendering `source` as `Crinja::Template` does (default `trim_blocks`, `lstrip_blocks`), or why not: a node is
  # unsupported or the source does not parse (an app tag, a vendored page). Crinja serves those at runtime.
  private def self.emit(source : String) : String | Unsupported
    @@filters, @@hoisted, @@locals, @@plain = [] of String, "", nil, false
    nodes(Crinja::Parser::TemplateParser.new(Crinja.new, source.rchop('\n')).parse.children)
  rescue e : Fallback
    unsupported(e.at, e.message.to_s)
  rescue e : Crinja::Error
    unsupported(e.location_start, e.message.to_s.lines.first? || e.class.name)
  rescue e : ArgumentError # Crinja's parser, for a number literal out of range
    unsupported(nil, e.message.to_s)
  end

  # The filters of the template being emitted, in order of first use: the code calls the `n`th as `filters[n]`.
  @@filters = [] of String

  # Locals assigned once, in a scope of the template's own, before its proc, which captures them: a loop's names.
  @@hoisted = ""

  # Inside a loop whose names are Crystal locals (name => local), and what its fast path asks at runtime: that each
  # filter is Crinja's own (`own[n]`) and that no loop name is a function, which `env.resolve` would return instead.
  @@locals : Hash(String, String)? = nil
  @@guard = [] of String

  # Set while emitting a loop's Crinja path: the loops inside it have no fast path either.
  @@plain = false

  # A loop body that can see its scope (it names `loop`): it runs in a `Crinja::Context` per item.
  private class Impure < Exception
  end

  # Crinja does not locate a `{# note #}`: it takes the end of the node before.
  private def self.nodes(list : Array(Crinja::AST::TemplateNode), after = Crinja::Parser::StreamPosition.new(1, 1, 0)) : String
    list.join do |node|
      at, after = node.location_start? || after, node.location_end? || after
      node(node, at)
    end
  end

  # One emitter per template node, as `Crinja::Renderer` renders it; a statement is located as the renderer does.
  private def self.node(node : Crinja::AST::TemplateNode, at) : String
    case node
    when Crinja::AST::FixedString    then "io << #{Crinja::Renderer.trim_text(node, false, false).inspect}; "
    when Crinja::AST::PrintStatement then located(node, "::Crinja::Finalizer.stringify(io, #{value(node.expression, at)}, env.context.autoescape?)") + "; "
    when Crinja::AST::TagNode        then located(node, for_loop(node, at)) + "; "
    else                                  raise Fallback.new(at, node.class.name.split("::").last)
    end
  end

  # `Crinja::Tag::For` without `if`, `recursive` or `else`: its `ForLoop`, with no scope where the body cannot see it.
  private def self.for_loop(node : Crinja::AST::TagNode, at) : String
    raise Fallback.new(at, node.name) unless node.name == "for" && node.end_tag
    raise Fallback.new(at, "for ... else") if node.block.children.any? { |child| child.is_a?(Crinja::AST::TagNode) && child.name == "else" }
    parsed = ForParser.new(node.arguments, Crinja::Config.new).parse_for
    raise Fallback.new(at, parsed) if parsed.is_a?(String)
    vars, collection = parsed
    looper = "looper#{at.pos}" # a local per loop: an inner loop's must not replace it
    @@hoisted += "#{looper}_vars = #{vars.inspect}; " if vars.size > 1
    head = "#{looper} = ::Crinja::Tag::For::ForLoop.new(#{value(collection, at)}); "
    locals = @@locals
    return head + fast_loop(node, vars, looper, at, locals) if locals # inside a fast loop
    fast = fast_loop?(node, vars, looper, at) unless @@plain
    head + (fast ? "if #{fast[0]}; #{fast[1]}; else; #{scoped_loop(node, vars, looper, at, true)}; end" : scoped_loop(node, vars, looper, at, @@plain))
  end

  # `Runner#run_loop`: a scope per item. `plain` when the loops inside it have no fast path.
  private def self.scoped_loop(node, vars, looper, at, plain : Bool) : String
    outer, @@plain = @@plain, plain
    unpack = vars.size == 1 ? "ctx[#{vars[0].inspect}] = item" : "ctx.unpack(#{looper}_vars, item)"
    "#{looper}.each { |item| env.with_scope(::Crinja::Context.new(env.context)) { |ctx| " \
    "ctx[::Crinja::Tag::For::LOOP_VARIABLE] = #{looper}; #{unpack}; #{nodes(node.block.children, at)}} }"
  ensure
    @@plain = outer unless outer.nil?
  end

  # The guard and code of the fast path of an outermost loop, or nil when its body can see the scope.
  private def self.fast_loop?(node, vars, looper, at) : {String, String}?
    @@guard.clear
    code = fast_loop(node, vars, looper, at, {} of String => String)
    {@@guard.uniq.join(" && "), code}
  rescue Impure
  ensure
    @@locals = nil
  end

  # `Runner#run_loop` with the item variables bound to Crystal locals, and no scope.
  private def self.fast_loop(node, vars, looper, at, outer : Hash(String, String)) : String
    locals = vars.map_with_index { |_, i| "v#{at.pos}_#{i}" }
    @@locals = scope = outer.dup
    vars.zip(locals) { |var, local| scope[var] = local; @@guard << "!env.functions.has_key?(#{var.inspect})" }
    unpack = vars.size == 1 ? "" : "#{locals.join(", ")} = ::Azu::Templates::CompiledTemplate.unpack(#{vars.size}, item); "
    "#{looper}.each { |#{vars.size == 1 ? locals[0] : "item"}| #{unpack}#{nodes(node.block.children, at)}}"
  ensure
    @@locals = outer
  end

  # What `Crinja::Evaluator#value` returns for `node`.
  private def self.value(node : Crinja::AST::ExpressionNode, at) : String
    "::Crinja::Value.new(#{expr(node, at)})"
  end

  # One emitter per expression node, for what `Crinja::Evaluator#evaluate` returns (a raw literal or a value).
  private def self.expr(node : Crinja::AST::ExpressionNode, at) : String
    case node
    when Crinja::AST::IdentifierLiteral                          then identifier(node.name)
    when Crinja::AST::StringLiteral, Crinja::AST::BooleanLiteral then node.value.inspect
    when Crinja::AST::IntegerLiteral                             then "#{node.value}_i64"
    when Crinja::AST::FloatLiteral                               then "#{node.value}_f64"
    when Crinja::AST::NullLiteral                                then "nil"
    when Crinja::AST::MemberExpression                           then attribute(node, node.identifier, node.member.name.inspect, false, at)
    when Crinja::AST::IndexExpression                            then attribute(node, node.identifier, expr(node.argument, at), true, at)
    when Crinja::AST::FilterExpression                           then located(node, filter(node, at))
    else                                                              raise Fallback.new(node.location_start? || at, node.class.name.split("::").last)
    end
  end

  # The local an enclosing loop binds `name` to, or `env.resolve`; inside such a loop, `loop` needs the scope.
  private def self.identifier(name : String) : String
    raise Impure.new if (locals = @@locals) && name == Crinja::Tag::For::LOOP_VARIABLE
    locals.try(&.[name]?) || "env.resolve(#{name.inspect})"
  end

  private def self.attribute(node, object, key : String, index : Bool, at) : String
    located(node, "::Azu::Templates::CompiledTemplate.attribute(#{value(object, at)}, #{key}, #{index}) { #{name(object, at)} }")
  end

  # `Crinja::Evaluator#evaluate_filter`: the filter, its arguments, keyword arguments and target, in that order.
  private def self.filter(node : Crinja::AST::FilterExpression, at) : String
    args = node.argumentlist.children.join(", ") do |arg|
      raise Fallback.new(arg.location_start? || at, "SplashOperator") if arg.is_a?(Crinja::AST::SplashOperator)
      value(arg, at)
    end
    kwargs = node.keyword_arguments.join { |key, arg| "kw[#{key.name.inspect}] = #{value(arg, at)}; " }
    name = node.identifier.name
    index = @@filters.index(name) || (@@filters << name).size - 1
    @@guard << "own[#{index}]" if @@locals
    "env.execute_call(filters[#{index}] || env.filters[#{name.inspect}], [#{args}] of ::Crinja::Value, " \
    "::Crinja::Variables.new.tap { |kw| #{kwargs}}, target: #{value(node.target, at)})"
  end

  # Code for the name `Crinja::Evaluator#name_for_expression` gives `node` (it raises for any other node).
  private def self.name(node : Crinja::AST::ExpressionNode, at) : String
    case node
    when Crinja::AST::IdentifierLiteral then node.name.inspect
    when Crinja::AST::MemberExpression  then "(#{name(node.identifier, at)} + #{".#{node.member.name}".inspect})"
    when Crinja::AST::IndexExpression   then %((#{name(node.identifier, at)} + "[" + #{expr(node.argument, at)}.to_s + "]"))
    else                                     %((raise #{"not implemented for #{node.class}".inspect}).as(::String))
    end
  end

  # Locates a `Crinja::Error` from `code` at `node`, as `Crinja::Renderer` and `Crinja::Evaluator` do.
  private def self.located(node, code : String) : String
    span = {node.location_start?, node.location_end?}.join(", ") { |pos| pos ? "::Crinja::Parser::StreamPosition.new(#{pos.line}, #{pos.column}, #{pos.pos})" : "nil" }
    "begin; #{code}; rescue e : ::Crinja::Error; raise e.has_location? ? e : e.at(#{span}); end"
  end

  private def self.unsupported(at : Crinja::Parser::StreamPosition?, what : String) : Unsupported
    Unsupported.new("#{position(at)}#{what}")
  end

  private def self.position(at : Crinja::Parser::StreamPosition?) : String
    at ? "#{at.line}:#{at.column}: " : ""
  end
end
