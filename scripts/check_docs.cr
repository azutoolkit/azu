require "file_utils"

# Type-checks the ```crystal blocks of the given Markdown files against this checkout of Azu, so
# documentation cannot drift away from the API unnoticed.
#
#     crystal run scripts/check_docs.cr -- README.md docs/tutorials/getting-started.md
#     crystal run scripts/check_docs.cr -- --shard 2/4 $(grep -v '^#' docs/.checked)
#
# `--shard i/n` (1-based) checks every n-th file of the list, starting at the i-th, so CI can split
# the list over n runners; the shards together cover every file exactly once.
#
# A block that is only a fragment (it needs a type another block defines, or a shard Azu does not
# depend on) opts out with `<!-- skip -->` on the line before its fence. A block without
# `require "azu"` gets one prepended. Blocks are compiled with `--no-codegen`, which resolves
# every constant and method call without building a binary.
#
# Crystal only type-checks a method body once something calls it, so a snippet that defines a
# method nobody calls would pass with a wrong body. A block that contains a `def` therefore gets
# BODY_CHECK appended: a `finished` macro that reopens each non-generic class and struct the block
# defines and adds a method calling each of that type's own methods (and the block's top-level
# methods) with `uninitialized` arguments of their declared types, inside `if false`, so the bodies
# are type-checked and never run. Skipped: `initialize` and `new`, modules, generic and abstract types, methods that take a
# block or splat, have untyped parameters or free variables, operators and setters.
module DocsCheck
  record Snippet, file : String, line : Int32, source : String

  FENCE_OPEN = /\A```crystal\s*\z/
  SKIP_MARK  = "<!-- skip -->"
  WORKERS    = 4

  BODY_CHECK = <<-'CR'

    macro finished
      {% def_lines = [DEF_LINES] %}
      {% name_pattern = /\A[a-z_][A-Za-z0-9_]*[?!]?\z/ %}
      {% for t, ti in Reference.all_subclasses + Struct.all_subclasses %}
        {% if t.type_vars.empty? && !t.abstract? && !t.name.includes?("(") %}
          {% inst = t.methods.select { |m| m.filename == __FILE__ && def_lines.includes?(m.line_number) && !m.abstract? && m.name =~ name_pattern && m.name != "initialize" && m.name != "new" && !m.block_arg && !m.splat_index && !m.double_splat && m.free_vars.empty? && !m.body.stringify.includes?("yield") && m.args.all? { |a| a.default_value || !a.restriction.is_a?(Nop) } } %}
          {% cls = t.class.methods.select { |m| m.filename == __FILE__ && def_lines.includes?(m.line_number) && !m.abstract? && m.name =~ name_pattern && m.name != "initialize" && m.name != "new" && !m.block_arg && !m.splat_index && !m.double_splat && m.free_vars.empty? && !m.body.stringify.includes?("yield") && m.args.all? { |a| a.default_value || !a.restriction.is_a?(Nop) } } %}
          {% if !inst.empty? || !cls.empty? %}
            {{ t.struct? ? "struct".id : "class".id }} {{ t.id }}
              {% if !inst.empty? %}
                def __azu_docs_check
                  if false
                    {% for m, mi in inst %}
                      {% for a, i in m.args.reject(&.default_value) %}__a{{ mi }}_{{ i }} = uninitialized {{ a.restriction }}; {% end %}{{ m.name.id }}({% for a, i in m.args.reject(&.default_value) %}{% if i > 0 %}, {% end %}__a{{ mi }}_{{ i }}{% end %})
                    {% end %}
                  end
                end
              {% end %}
              {% if !cls.empty? %}
                def self.__azu_docs_check
                  if false
                    {% for m, mi in cls %}
                      {% for a, i in m.args.reject(&.default_value) %}__a{{ mi }}_{{ i }} = uninitialized {{ a.restriction }}; {% end %}{{ m.name.id }}({% for a, i in m.args.reject(&.default_value) %}{% if i > 0 %}, {% end %}__a{{ mi }}_{{ i }}{% end %})
                    {% end %}
                  end
                end
              {% end %}
            end
            if false
              {% if !inst.empty? %}__obj{{ ti }} = uninitialized {{ t.id }}; __obj{{ ti }}.__azu_docs_check{% end %}
              {% if !cls.empty? %}{{ t.id }}.__azu_docs_check{% end %}
            end
          {% end %}
        {% end %}
      {% end %}
      {% top = @top_level.methods.select { |m| m.filename == __FILE__ && def_lines.includes?(m.line_number) && !m.abstract? && m.name =~ name_pattern && m.name != "initialize" && m.name != "new" && !m.block_arg && !m.splat_index && !m.double_splat && m.free_vars.empty? && !m.body.stringify.includes?("yield") && m.args.all? { |a| a.default_value || !a.restriction.is_a?(Nop) } } %}
      if false
        {% for m, mi in top %}
          {% for a, i in m.args.reject(&.default_value) %}__a{{ mi }}_{{ i }} = uninitialized {{ a.restriction }}; {% end %}{{ m.name.id }}({% for a, i in m.args.reject(&.default_value) %}{% if i > 0 %}, {% end %}__a{{ mi }}_{{ i }}{% end %})
        {% end %}
      end
    end
  CR

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

  # BODY_CHECK for `source`, limited to the methods written on a `def` line of the block itself: methods
  # that a macro generates report the macro call's file and line, and are not the documentation's code.
  def self.body_check(source : String) : String
    lines = source.lines.each_with_index.select { |line, _| line.matches?(/^\s*def /) }.map { |_, index| index + 1 }.to_a
    lines.empty? ? "" : BODY_CHECK.sub("DEF_LINES", lines.join(", "))
  end

  # Returns nil when the snippet compiles, otherwise the compiler's first error line.
  def self.failure(snippet : Snippet, dir : String, id : Int32) : String?
    source = snippet.source.includes?(%(require "azu")) ? snippet.source : %(require "azu"\n) + snippet.source
    source += body_check(source)
    path = File.join(dir, "snippet_#{id}.cr")
    File.write(path, source)
    message = compile(path)
    # Crystal builds its ECR helper into a shared cache on first use; a compile that starts while another
    # one is still writing it fails with "macro_run: Permission denied". The snippet is fine: try once more.
    message = compile(path) if message && message.includes?("macro_run")
    message
  end

  private def self.compile(path : String) : String?
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

  # The files of shard `index` out of `count` (1-based): every `count`-th file, starting at `index`.
  def self.shard(files : Array(String), index : Int32, count : Int32) : Array(String)
    files.each_with_index.select { |_, position| position % count == index - 1 }.map(&.first).to_a
  end

  def self.parse_shard(spec : String) : {Int32, Int32}
    index, count = spec.split('/', 2).map(&.to_i)
    raise ArgumentError.new("shard #{spec} is out of range") unless count >= 1 && 1 <= index <= count
    {index, count}
  rescue ArgumentError | IndexError
    abort "--shard expects i/n with 1 <= i <= n, got #{spec}"
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

args = ARGV.to_a
if position = args.index("--shard")
  spec = args[position + 1]? || abort("--shard expects i/n")
  args.delete_at(position, 2)
  index, count = DocsCheck.parse_shard(spec)
  args = DocsCheck.shard(args, index, count)
end
exit DocsCheck.run(args)
