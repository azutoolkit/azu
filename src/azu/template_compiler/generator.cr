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
        "#{name.inspect} => {#{source.inspect}, ->(io : ::IO, env : ::Crinja) { #{body}nil }}"
      in Unsupported
        fallbacks[name] = "#{name}:#{body.reason}"
        nil
      end
    end
    raise Error.new("Azu::Templates.compile: cannot compile #{fallbacks.values.join(", ")}") if strict && fallbacks.present?
    "::Azu::Templates::CompiledSet.new({#{entries.join(", ")}} of ::String => {::String, ::Proc(::IO, ::Crinja, ::Nil)}, " \
    "#{fallbacks.inspect} of ::String => ::String)"
  end

  # Code rendering `source` as `Crinja::Template` does (default `trim_blocks`, `lstrip_blocks`), or why not: a node is
  # unsupported or the source does not parse (an app tag, a vendored page). Crinja serves those at runtime.
  private def self.emit(source : String) : String | Unsupported
    after = Crinja::Parser::StreamPosition.new(1, 1, 0) # Crinja does not locate a `{# note #}`: it follows the node before
    Crinja::Parser::TemplateParser.new(Crinja.new, source.rchop('\n')).parse.children.join do |node|
      at, after = node.location_start? || after, node.location_end? || after
      next "io << #{Crinja::Renderer.trim_text(node, false, false).inspect}; " if node.is_a?(Crinja::AST::FixedString)
      name = node.as?(Crinja::AST::PrintStatement).try(&.expression.as?(Crinja::AST::IdentifierLiteral)).try(&.name)
      return unsupported(at, node.as?(Crinja::AST::TagNode).try(&.name) || node.class.name.split("::").last) unless name
      # locates a render error at the statement, as Crinja's renderer does
      span = {node.location_start, node.location_end}.join(", ") { |pos| "::Crinja::Parser::StreamPosition.new(#{pos.line}, #{pos.column}, #{pos.pos})" }
      "begin; io << env.stringify(env.resolve(#{name.inspect})); rescue e : ::Crinja::Error; raise e.has_location? ? e : e.at(#{span}); end; "
    end
  rescue e : Crinja::Error
    unsupported(e.location_start, e.message.to_s.lines.first? || e.class.name)
  end

  private def self.unsupported(at : Crinja::Parser::StreamPosition?, what : String) : Unsupported
    Unsupported.new(at ? "#{at.line}:#{at.column}: #{what}" : " #{what}")
  end
end
