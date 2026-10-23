# Which Markdown files have ```crystal blocks but are not listed in docs/.checked.
module DocsListed
  FENCE = /^```crystal\s*$/

  # Files under *root* (README.md and docs/**/*.md, except docs/plans/) that contain a crystal block.
  def self.with_crystal_blocks(root : String) : Array(String)
    candidates = Dir.glob(File.join(root, "docs", "**", "*.md")) + [File.join(root, "README.md")]
    candidates
      .reject { |path| path.includes?("/docs/plans/") }
      .select { |path| File.file?(path) && File.read_lines(path).any?(&.matches?(FENCE)) }
      .map { |path| Path[path].relative_to(root).to_s }
      .sort
  end

  def self.listed(root : String) : Array(String)
    File.read_lines(File.join(root, "docs", ".checked")).map(&.strip).reject { |line| line.empty? || line.starts_with?('#') }
  end

  def self.missing(root : String) : Array(String)
    with_crystal_blocks(root) - listed(root)
  end
end
