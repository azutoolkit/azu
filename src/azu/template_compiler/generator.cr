module Azu::TemplateCompiler
  # Each directory is globbed from inside, so a `[` in its name is no pattern; the first that has a name wins.
  def self.generate(dirs : Array(String)) : String
    entries = {} of String => String? # nil: not supported, and the name stays taken
    dirs.select { |dir| Dir.exists?(dir) }.each do |dir|
      Dir.cd(dir) { Dir.glob("**/*.{html,jinja,j2}").sort! }.reject { |name| entries.has_key?(name) }.each do |name|
        source = File.read(File.join(dir, name))
        entries[name] = emit(source).try { |body| "#{name.inspect} => {#{source.inspect}, ->(io : ::IO, env : ::Crinja) { #{body}nil }}" }
      end
    end
    "::Azu::Templates::CompiledSet.new({#{entries.values.compact.join(", ")}} of ::String => {::String, ::Proc(::IO, ::Crinja, ::Nil)})"
  end

  # Code rendering `source` as `Crinja::Template` does (default `trim_blocks`, `lstrip_blocks`); nil if a node is unsupported.
  private def self.emit(source : String) : String?
    Crinja::Parser::TemplateParser.new(Crinja.new, source.rchop('\n')).parse.children.join do |node|
      next "io << #{Crinja::Renderer.trim_text(node, false, false).inspect}; " if node.is_a?(Crinja::AST::FixedString)
      name = node.as?(Crinja::AST::PrintStatement).try(&.expression.as?(Crinja::AST::IdentifierLiteral)).try(&.name) || return
      "io << env.stringify(env.resolve(#{name.inspect})); "
    end
  end
end
