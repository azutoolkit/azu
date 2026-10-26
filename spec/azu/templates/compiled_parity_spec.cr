require "../../spec_helper"

COMPILED_FIXTURES = Azu::Templates.compile("spec/fixtures/compiled")

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
