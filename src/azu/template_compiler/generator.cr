module Azu::TemplateCompiler
  # Globbed from inside `dir`, so a `[` in its name is no pattern.
  def self.generate(dir : String) : String
    entries = Dir.cd(dir) { Dir.glob("**/*.{html,jinja,j2}").sort! }.compact_map do |name|
      source = File.read(File.join(dir, name))
      emit(source).try { |body| "#{name.inspect} => {#{source.inspect}, ->(io : ::IO, env : ::Crinja) { #{body}nil }}" }
    end
    "::Azu::Templates::CompiledSet.new({#{entries.join(", ")}} of ::String => {::String, ::Proc(::IO, ::Crinja, ::Nil)})"
  end

  # Code rendering `source` as `Crinja::Template` does (default `trim_blocks`, `lstrip_blocks`); nil if a node is
  # unsupported or the source does not parse (an app tag, a vendored page): Crinja serves those at runtime.
  private def self.emit(source : String) : String?
    Crinja::Parser::TemplateParser.new(Crinja.new, source.rchop('\n')).parse.children.join do |node|
      next "io << #{Crinja::Renderer.trim_text(node, false, false).inspect}; " if node.is_a?(Crinja::AST::FixedString)
      name = node.as?(Crinja::AST::PrintStatement).try(&.expression.as?(Crinja::AST::IdentifierLiteral)).try(&.name) || return
      # locates a render error at the statement, as Crinja's renderer does
      at = {node.location_start, node.location_end}.join(", ") { |pos| "::Crinja::Parser::StreamPosition.new(#{pos.line}, #{pos.column}, #{pos.pos})" }
      "begin; io << env.stringify(env.resolve(#{name.inspect})); rescue e : ::Crinja::Error; raise e.has_location? ? e : e.at(#{at}); end; "
    end
  rescue Crinja::Error
    nil
  end
end
