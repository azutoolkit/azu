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
    fallbacks.should be_a Hash(String, String)
    fallbacks.keys.should contain "comment.jinja"
    fallbacks.keys.should contain "raw.jinja"
    fallbacks.keys.should contain "if.jinja"
    {"hello.jinja", "text.jinja", "empty.jinja", "trim.jinja", "quotes.jinja"}.each do |name|
      fallbacks.keys.should_not contain name
    end
  end
end
