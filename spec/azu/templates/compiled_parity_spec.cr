require "../../spec_helper"

COMPILED_FIXTURES = Azu::Templates.compile("spec/fixtures/compiled")
COMPILED_BROKEN   = Azu::Templates.compile("spec/fixtures/compiled_broken") # its broken.jinja would stop other examples' prepare

private HOSTILE = %(<b>&"x"</b>)

private def build(hot_reload : Bool, compiled : Bool = false) : Azu::Templates
  templates = Azu::Templates.new(["spec/fixtures/compiled"], File.join(Dir.tempdir, "azu_compiled_errors"), hot_reload: hot_reload)
  templates.compiled = COMPILED_FIXTURES if compiled
  templates
end

private def variables(name : String) : Crinja::Variables
  Crinja::Variables.new.tap { |vars| vars["name"] = Crinja::Value.new(name) }
end

describe "Azu::Templates compiled templates (literal text and {{ identifier }})" do
  it "loads a CompiledTemplate with reload off, and Crinja's own template with reload on" do
    build(hot_reload: false, compiled: true).load("hello.jinja").should be_a Azu::Templates::CompiledTemplate

    reloading = build(hot_reload: true, compiled: true).load("hello.jinja")
    reloading.should be_a Crinja::Template
    reloading.should_not be_a Azu::Templates::CompiledTemplate
  end

  it "escapes like Crinja with autoescape on" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)
    compiled.autoescape = true
    reloading.autoescape = true

    output = compiled.load("hello.jinja").render({"name" => HOSTILE})
    output.should eq "<p>Hello &lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;</p>"
    output.should eq reloading.load("hello.jinja").render({"name" => HOSTILE})
  end

  it "does not escape like Crinja with autoescape off, switched at runtime on the same instances" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)
    compiled.autoescape = true
    reloading.autoescape = true
    compiled.load("hello.jinja").render({"name" => HOSTILE})

    compiled.autoescape = false
    reloading.autoescape = false

    output = compiled.load("hello.jinja").render({"name" => HOSTILE})
    output.should eq %(<p>Hello <b>&"x"</b></p>)
    output.should eq reloading.load("hello.jinja").render({"name" => HOSTILE})
  end

  it "prints an undefined variable as an empty string, like Crinja" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)

    compiled.render("hello.jinja").should eq "<p>Hello </p>"
    compiled.render("hello.jinja").should eq reloading.render("hello.jinja")
  end

  it "renders through Templates#render with the compiled template, like Crinja" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)

    compiled.load("hello.jinja").should be_a Azu::Templates::CompiledTemplate
    compiled.render("hello.jinja", {"name" => "Ada"}).should eq "<p>Hello Ada</p>"
    compiled.render("hello.jinja", {"name" => "Ada"}).should eq reloading.render("hello.jinja", {"name" => "Ada"})
  end

  it "renders through Templates#render_variables (what view uses) with the compiled template, like Crinja" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)

    compiled.load("hello.jinja").should be_a Azu::Templates::CompiledTemplate
    compiled.render_variables("hello.jinja", variables("Ada")).should eq "<p>Hello Ada</p>"
    compiled.render_variables("hello.jinja", variables(HOSTILE)).should eq reloading.render_variables("hello.jinja", variables(HOSTILE))
  end

  it "drops the one trailing newline of the file, like Crinja" do
    File.read("spec/fixtures/compiled/hello.jinja").should end_with "</p>\n"

    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)

    output = compiled.render("hello.jinja", {"name" => "Ada"})
    output.should_not end_with "\n"
    output.should eq reloading.render("hello.jinja", {"name" => "Ada"})
  end
end

describe "Azu::Templates compiled templates mixed with Crinja's" do
  it "renders a Crinja child that extends a compiled parent like Crinja" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)

    compiled.load("child.jinja").should_not be_a Azu::Templates::CompiledTemplate
    compiled.render("child.jinja", {"name" => "Ada"}).should eq "<p>Hello Ada</p>"
    compiled.render("child.jinja", {"name" => "Ada"}).should eq reloading.render("child.jinja", {"name" => "Ada"})
  end
end

private class Boom
  include Crinja::Object

  def to_s(io : IO) : Nil
    raise Crinja::RuntimeError.new("boom")
  end
end

# Templates below a fresh directory, written by the block; the files differ from the compiled ones of the same name.
private def with_dir(&)
  dir = File.join(Dir.tempdir, "azu_compiled_#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "Azu::Templates compiled templates, fallbacks and parity" do
  it "renders each fixture like Crinja, compiled only when every node is supported" do
    {"trim.jinja" => true, "empty.jinja" => true, "text.jinja" => true, "quotes.jinja" => true, "comment.jinja" => false,
     "raw.jinja" => false, "if.jinja" => false, "include.jinja" => false}.each do |name, supported|
      template = build(hot_reload: false, compiled: true).load(name)
      (template.class == Azu::Templates::CompiledTemplate).should eq(supported), name
      template.render({"name" => "Ada"}).should eq(build(hot_reload: true).render(name, {"name" => "Ada"})), name
    end
  end

  it "uses a compiled template only for the file it was compiled from" do
    with_dir do |dir|
      File.write(File.join(dir, "hello.jinja"), "<p>Changed {{ name }}</p>\n")
      [[dir], [dir, "spec/fixtures/compiled"]].each do |paths|
        compiled = Azu::Templates.new(paths, File.join(dir, "errors"), hot_reload: false)
        compiled.compiled = COMPILED_FIXTURES
        compiled.load("hello.jinja").should_not be_a Azu::Templates::CompiledTemplate
        compiled.render("hello.jinja", {"name" => "Ada"}).should eq "<p>Changed Ada</p>"
      end
    end
  end

  it "keeps the trailing newline like Crinja when keep_trailing_newline is on" do
    compiled = build(hot_reload: false, compiled: true)
    reloading = build(hot_reload: true)
    compiled.crinja.config.keep_trailing_newline = true
    reloading.crinja.config.keep_trailing_newline = true

    compiled.render("hello.jinja", {"name" => "Ada"}).should eq "<p>Hello Ada</p>\n"
    compiled.render("hello.jinja", {"name" => "Ada"}).should eq reloading.render("hello.jinja", {"name" => "Ada"})
  end

  it "replaces an already preloaded map when compiled= is set" do
    templates = build(hot_reload: false)
    templates.load("hello.jinja").should_not be_a Azu::Templates::CompiledTemplate
    templates.compiled = COMPILED_FIXTURES
    templates.load("hello.jinja").should be_a Azu::Templates::CompiledTemplate
  end

  it "raises a render error naming the template, like Crinja" do
    errors = [build(hot_reload: false, compiled: true), build(hot_reload: true)].map do |templates|
      expect_raises(Crinja::Error) { templates.render("hello.jinja", {"name" => Boom.new}) }
    end
    errors[0].template.try(&.name).should eq "hello.jinja"
    errors[0].template.try(&.name).should eq errors[1].template.try(&.name)
    errors[0].message.should eq errors[1].message
  end
end

describe "Azu::Templates compiled templates (for with if, recursive or else)" do
  {"for_if.jinja" => "for ... if", "for_recursive.jinja" => "for ... recursive", "for_else.jinja" => "for ... else"}.each do |name, reason|
    it "falls back to Crinja for #{reason}, rendering like it" do
      COMPILED_FIXTURES.fallbacks[name].should eq "#{name}:1:1: #{reason}"
      data = {"xs" => ["a", "b"], "ys" => [] of String}
      output = build(hot_reload: false, compiled: true).render(name, data)
      output.should_not be_empty
      output.should eq build(hot_reload: true).render(name, data)
    end
  end
end

describe "Azu::Templates compiled templates next to one that does not parse" do
  it "leaves it out of the build and to Crinja, which fails it as it does without a compiled set" do
    COMPILED_BROKEN.templates.keys.should eq ["good.jinja"]
    errors = [true, false].map do |with_compiled|
      templates = Azu::Templates.new(["spec/fixtures/compiled_broken"], File.join(Dir.tempdir, "azu_compiled_errors"), hot_reload: false)
      templates.compiled = COMPILED_BROKEN if with_compiled
      templates.load("good.jinja").class.should eq(with_compiled ? Azu::Templates::CompiledTemplate : Crinja::Template)
      lazy = expect_raises(Crinja::TemplateSyntaxError) { templates.load("broken.jinja") }
      {lazy.message, expect_raises(Azu::Templates::CompileError) { templates.prepare }.message}
    end
    errors[0].should eq errors[1]
  end
end

describe "Azu::Templates compiled templates (fallbacks)" do
  it "records the templates that fell back to Crinja" do
    fallbacks = COMPILED_FIXTURES.fallbacks
    fallbacks["raw.jinja"].should eq "raw.jinja:1:1: raw"
    fallbacks.keys.should contain "comment.jinja"
    fallbacks.keys.should contain "raw.jinja"
    fallbacks.keys.should contain "if.jinja"
    {"hello.jinja", "text.jinja", "empty.jinja", "trim.jinja", "quotes.jinja"}.each do |name|
      fallbacks.keys.should_not contain name
    end
  end
end

COMPILED_LOOPS = Azu::Templates.compile("spec/fixtures/compiled_loops")

private def loops(hot_reload : Bool, compiled : Bool = false) : Azu::Templates
  templates = Azu::Templates.new(["spec/fixtures/compiled_loops"], File.join(Dir.tempdir, "azu_compiled_errors"), hot_reload: hot_reload)
  templates.compiled = COMPILED_LOOPS if compiled
  templates
end

private def bench_items : Array(Hash(String, Crinja::Value))
  ["Item 1 & <co>", "Item 2", "Item \"3\""].map_with_index do |name, i|
    {"id" => Crinja::Value.new(i + 1), "name" => Crinja::Value.new(name), "price" => Crinja::Value.new((i + 1) * 100)}
  end
end

describe "Azu::Templates compiled templates (for, member and index access, filters)" do
  it "compiles every loops fixture, with no fallbacks" do
    COMPILED_LOOPS.fallbacks.should be_empty
  end

  {
    "bench.jinja"      => {"items" => bench_items},
    "member.jinja"     => {"user" => {"name" => "Ada <b>", "address" => {"city" => "Paris"}}},
    "index.jinja"      => {"row" => {"a" => "A&"}, "list" => ["x", "y<"]},
    "filters.jinja"    => {"x" => "<i>&", "name" => "ada"},
    "nested_for.jinja" => {"rows" => [["a", "b&"], ["c"], [] of String]},
    "for_scope.jinja"  => {"item" => "outer<", "items" => ["1", "2&"]},
    "for_hash.jinja"   => {"table" => {"k1" => "v1", "k2" => "v2"}},
    "loop.jinja"       => {"rows" => [["a", "b"], ["c"]]},
    "emitters.jinja"   => {"s" => "a\nb", "row" => {"k" => "v"}, "key" => "k"},
    "shadow.jinja"     => {"xs" => [["a", "b"], ["c"]], "x" => "top"},
  }.each do |name, data|
    it "renders #{name} as a CompiledTemplate, byte-identical to Crinja" do
      compiled = loops(hot_reload: false, compiled: true)
      reloading = loops(hot_reload: true)

      compiled.load(name).should be_a Azu::Templates::CompiledTemplate
      expected = reloading.render(name, data)
      expected.should_not be_empty
      compiled.render(name, data).should eq expected
    end
  end

  it "renders the benchmark page through render_variables like Crinja, escaping names" do
    compiled = loops(hot_reload: false, compiled: true)
    reloading = loops(hot_reload: true)
    vars = -> { Crinja::Variables.new.tap { |v| v["items"] = Crinja::Value.new(bench_items) } }

    compiled.load("bench.jinja").should be_a Azu::Templates::CompiledTemplate
    output = compiled.render_variables("bench.jinja", vars.call)
    output.should contain %(<li class="item-1">Item 1 &amp; &lt;co&gt; (100)</li>)
    output.should eq reloading.render_variables("bench.jinja", vars.call)
  end

  it "renders the benchmark page with autoescape off like Crinja" do
    compiled = loops(hot_reload: false, compiled: true)
    reloading = loops(hot_reload: true)
    compiled.autoescape = false
    reloading.autoescape = false

    compiled.load("bench.jinja").should be_a Azu::Templates::CompiledTemplate
    compiled.render("bench.jinja", {"items" => bench_items}).should eq reloading.render("bench.jinja", {"items" => bench_items})
  end

  it "renders a for over an undefined variable as an empty loop, like Crinja, and does not leak the loop variable" do
    compiled = loops(hot_reload: false, compiled: true)
    reloading = loops(hot_reload: true)

    compiled.load("for_scope.jinja").should be_a Azu::Templates::CompiledTemplate
    compiled.render("for_scope.jinja", {"item" => "outer"}).should eq "outer||outer"
    compiled.render("for_scope.jinja", {"item" => "outer"}).should eq reloading.render("for_scope.jinja", {"item" => "outer"})
    compiled.render("for_scope.jinja").should eq reloading.render("for_scope.jinja")
  end
end

describe "Azu::Templates compiled templates (whitespace options, errors)" do
  {"trim_blocks" => ->(c : Crinja::Config) { c.trim_blocks = true }, "lstrip_blocks" => ->(c : Crinja::Config) { c.lstrip_blocks = true }}.each do |option, set|
    it "renders like Crinja with #{option} on" do
      compiled = loops(hot_reload: false, compiled: true)
      reloading = loops(hot_reload: true)
      set.call(compiled.crinja.config)
      set.call(reloading.crinja.config)
      compiled.render("blocks.jinja", {"xs" => ["a", "b"]}).should eq reloading.render("blocks.jinja", {"xs" => ["a", "b"]})
    end
  end

  {
    {"unknown_filter.jinja", {"x" => 1}},
    {"member_error.jinja", {"v" => 1}},             # u undefined
    {"member_error.jinja", {"u" => {"x" => 1}}},    # u.a undefined
    {"loop_error.jinja", {"xs" => [[{"k" => 1}]]}}, # a.c undefined in the loop body
    {"loop_error.jinja", {"xs" => nil}},
    {"loop_error.jinja", {"xs" => 1}},
    {"loop_error.jinja", {"xs" => [1]}},           # bad unpack
    {"undefined_name.jinja", {"u" => {"a" => 1}}}, # the error names u.missing
  }.each do |name, data|
    it "raises like Crinja for #{name} with #{data}" do
      loops(hot_reload: false, compiled: true).load(name).should be_a Azu::Templates::CompiledTemplate
      errors = {loops(hot_reload: false, compiled: true), loops(hot_reload: true)}.map do |templates|
        expect_raises(Crinja::Error) { templates.render(name, data) }
      end
      compiled, crinja = errors.map { |e| {e.class, e.message, e.location_start, e.template.try(&.name)} }
      compiled.should eq crinja
    end
  end
end

private class Shown
  include Crinja::Object

  def to_s(io : IO) : Nil
    io << "<o & o>"
  end
end

describe "Azu::Templates compiled templates (values written to io, loops without a scope)" do
  it "prints every kind of value like Crinja, in and out of a loop, with autoescape on and off" do
    vals = [1, 1.5, nil, true, "<a>", Crinja::SafeString.new("<b>"), [1, "x<"], {"k" => "<v>"}, Time.utc(2020, 1, 2), Shown.new]
    data = {"vals" => vals.map { |val| Crinja::Value.new(val) }, "h" => {"k<" => "v>"}}
    [true, false].each do |escape|
      compiled, reloading = loops(hot_reload: false, compiled: true), loops(hot_reload: true)
      {compiled, reloading}.each(&.autoescape=(escape))
      compiled.render("values.jinja", data).should eq reloading.render("values.jinja", data)
    end
  end

  it "runs a loop in a scope, like Crinja, when a filter it calls is not Crinja's own (the filter reads the scope)" do
    outputs = {loops(hot_reload: false, compiled: true), loops(hot_reload: true)}.map do |templates|
      templates.crinja.filters["upper"] = Crinja.filter { "#{target}@#{env.resolve("item")}" }
      templates.render("loop_filter.jinja", {"items" => ["a", "b"], "item" => "top"})
    end
    outputs.should eq({"a@a,b@b,", "a@a,b@b,"})
  end

  it "resolves a loop variable named like a function to the function, like Crinja" do
    function = Crinja.function { "F" }
    outputs = {loops(hot_reload: false, compiled: true), loops(hot_reload: true)}.map do |templates|
      templates.crinja.functions["item"] = function
      templates.render("loop_filter.jinja", {"items" => ["a"]})
    end
    outputs[0].should_not eq "A,"
    outputs[0].should eq outputs[1]
  end
end

describe "Azu::Templates compiled templates (which filters a loop without a scope trusts)" do
  it "runs a loop in a scope, like Crinja, for Azu's active_class (it reads current_path)" do
    outputs = {loops(hot_reload: false, compiled: true), loops(hot_reload: true)}.map do |templates|
      templates.render("active_loop.jinja", {"paths" => ["/a", "/b"]})
    end
    outputs.should eq({"active,,", "active,,"})
  end

  it "trusts none of Azu's helper filters, and Crinja's own upper" do
    filters = loops(hot_reload: true).crinja.filters
    %w[active_class is_current_page urlize].each do |name|
      Azu::Templates::CompiledTemplate::CONTEXT_FREE.none?(&.same?(filters[name])).should be_true, name
    end
    Azu::Templates::CompiledTemplate::CONTEXT_FREE.any?(&.same?(Crinja.new.filters["upper"])).should be_true
  end

  it "runs a loop in a scope, like Crinja, for a named override of a built-in that reads the scope" do
    override = Crinja.filter(:upper) { "#{target}@#{env.resolve("item")}" }
    outputs = {loops(hot_reload: false, compiled: true), loops(hot_reload: true)}.map do |templates|
      templates.crinja.filters["upper"] = override
      templates.render("loop_filter.jinja", {"items" => ["a", "b"], "item" => "top"})
    end
    outputs.should eq({"a@a,b@b,", "a@a,b@b,"})
  ensure
    Crinja::Filter::Library.defaults.delete(override) if override
  end

  it "runs a loop in a scope, like Crinja, when map calls a filter that reads the scope" do
    outputs = {loops(hot_reload: false, compiled: true), loops(hot_reload: true)}.map do |templates|
      templates.crinja.filters["probe"] = Crinja.filter { "#{target}@#{env.resolve("item")}" }
      templates.render("map_loop.jinja", {"items" => ["a", "b"], "item" => "top"})
    end
    outputs.should eq({"a@a,a@b,", "a@a,a@b,"})
  end

  it "takes the fast path for Crinja's own filters" do
    templates = loops(hot_reload: false, compiled: true)
    template = templates.load("bench.jinja").as(Azu::Templates::CompiledTemplate)
    templates.render("bench.jinja", {"items" => bench_items})
    template.@state.get.try(&.own).should eq [true]
  end
end
