require "file_utils"

# Type-checks the ```crystal blocks of the given Markdown files against this checkout of Azu, so
# documentation cannot drift away from the API unnoticed.
#
#     crystal run scripts/check_docs.cr -- README.md docs/tutorials/getting-started.md
#
# A block that is only a fragment (it needs a type another block defines, or a shard Azu does not
# depend on) opts out with `<!-- skip -->` on the line before its fence. A block without
# `require "azu"` gets one prepended. Blocks are compiled with `--no-codegen`, which resolves
# every constant and method call without building a binary.
module DocsCheck
  record Snippet, file : String, line : Int32, source : String

  FENCE_OPEN = /\A```crystal\s*\z/
  SKIP_MARK  = "<!-- skip -->"
  WORKERS    = 4

  def self.snippets(file : String) : Array(Snippet)
    found = [] of Snippet
    lines = File.read_lines(file)
    index = 0
    while index < lines.size
      if lines[index].matches?(FENCE_OPEN)
        skipped = index > 0 && lines[index - 1].strip == SKIP_MARK
        start = index + 1
        index += 1
        body = [] of String
        while index < lines.size && lines[index].strip != "```"
          body << lines[index]
          index += 1
        end
        found << Snippet.new(file, start + 1, body.join('\n') + "\n") unless skipped
      end
      index += 1
    end
    found
  end

  # Returns nil when the snippet compiles, otherwise the compiler's first error line.
  def self.failure(snippet : Snippet, dir : String, id : Int32) : String?
    source = snippet.source.includes?(%(require "azu")) ? snippet.source : %(require "azu"\n) + snippet.source
    path = File.join(dir, "snippet_#{id}.cr")
    File.write(path, source)
    error = IO::Memory.new
    status = Process.run("crystal", ["build", "--no-codegen", "--no-color", path], error: error, output: Process::Redirect::Close)
    return if status.success?
    error.to_s.lines.find(&.starts_with?("Error")) || error.to_s.lines.first? || "compile failed"
  end

  # The first compile that requires Azu builds Crystal's ECR helper into the shared cache; four
  # compiles doing that at once race each other, so do it once before starting the workers.
  def self.warm_cache(dir : String) : Nil
    path = File.join(dir, "warmup.cr")
    File.write(path, %(require "azu"\n))
    Process.run("crystal", ["build", "--no-codegen", "--no-color", path], error: Process::Redirect::Close, output: Process::Redirect::Close)
  end

  def self.run(files : Array(String)) : Int32
    root = Dir.current
    ENV["CRYSTAL_PATH"] = "#{File.join(root, "src")}:lib:#{`crystal env CRYSTAL_PATH`.strip}"
    all = files.flat_map { |file| snippets(file) }
    dir = File.tempname("azu-docs-check")
    Dir.mkdir_p(dir)
    warm_cache(dir)

    results = Channel({Snippet, String?}).new
    queue = Channel({Snippet, Int32}).new
    WORKERS.times do
      spawn do
        while job = queue.receive?
          snippet, id = job
          results.send({snippet, failure(snippet, dir, id)})
        end
      end
    end
    spawn do
      all.each_with_index { |snippet, id| queue.send({snippet, id}) }
      queue.close
    end

    failed = all.compact_map do
      snippet, error = results.receive
      next unless error
      puts "#{snippet.file}:#{snippet.line}: #{error}"
      snippet
    end
    puts "#{all.size} snippets checked, #{failed.size} failed"
    failed.empty? ? 0 : 1
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

exit DocsCheck.run(ARGV.to_a)
