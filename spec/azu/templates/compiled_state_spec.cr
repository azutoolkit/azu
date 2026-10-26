require "../../spec_helper"

COMPILED_STATE = Azu::Templates.compile("spec/fixtures/compiled_loops")

private def filters_page : Azu::Templates
  templates = Azu::Templates.new(["spec/fixtures/compiled_loops"], File.join(Dir.tempdir, "azu_compiled_errors"), hot_reload: false)
  templates.compiled = COMPILED_STATE
  templates
end

describe "Azu::Templates compiled templates (filters resolved once)" do
  it "resolves each environment's own filters, and again when they change after a render" do
    shout, plain = filters_page, filters_page
    shout.crinja.filters["upper"] = Crinja.filter { "SHOUT" }
    data = {"x" => "x", "name" => "ada"}

    shout.load("filters.jinja").should be_a Azu::Templates::CompiledTemplate
    shout.render("filters.jinja", data).should eq "<p>x|none|SHOUT</p>"
    plain.render("filters.jinja", data).should eq "<p>x|none|ADA</p>"

    plain.crinja.filters["upper"] = Crinja.filter { "LATE" }
    plain.render("filters.jinja", data).should eq "<p>x|none|LATE</p>"
    plain.crinja.filters.disabled << "upper"
    expect_raises(Crinja::SecurityError, "is disabled") { plain.render("filters.jinja", data) }
  end

  it "sees a same-size change to the disabled filters and the aliases, as Crinja does" do
    page, data = filters_page, {"x" => "x", "name" => "ada"}
    crinja = page.crinja.from_string(File.read("spec/fixtures/compiled_loops/filters.jinja"))
    page.crinja.filters.disabled << "lower"
    page.render("filters.jinja", data).should eq "<p>x|none|ADA</p>"
    page.crinja.filters.disabled[0] = "upper"
    expect_raises(Crinja::SecurityError, "is disabled") { crinja.render(data) }
    expect_raises(Crinja::SecurityError, "is disabled") { page.render("filters.jinja", data) }

    page.crinja.filters.disabled.clear
    page.crinja.filters.aliases["upper"] = "capitalize"
    page.render("filters.jinja", data).should eq "<p>x|none|Ada</p>"
    page.crinja.filters.aliases["upper"] = "lower"
    page.render("filters.jinja", data).should eq crinja.render(data)
    page.render("filters.jinja", data).should eq "<p>x|none|ada</p>"
  end

  it "reads the autoescape rule on every render, so an in-place change applies" do
    page, data = filters_page, {"x" => "x", "name" => "<b>"}
    page.render("filters.jinja", data).should eq "<p>x|none|&lt;B&gt;</p>"
    page.crinja.config.autoescape.default = false
    page.render("filters.jinja", data).should eq "<p>x|none|<B></p>"
  end

  it "renders one compiled template with each environment's own filters" do
    template = filters_page.load("filters.jinja").as(Azu::Templates::CompiledTemplate)
    shout, plain = Crinja.new, Crinja.new
    shout.filters["upper"] = Crinja.filter { "SHOUT" }
    plain.filters["upper"] = Crinja.filter { "PLAIN" } # the same revision: only the env tells them apart
    shout.filters.revision.should eq plain.filters.revision
    data = Crinja.variables({"x" => "x", "name" => "ada"})
    render = ->(env : Crinja) { String.build { |io| env.with_scope(data) { template.render(io, env) } } }
    render.call(shout).should eq "<p>x|none|SHOUT</p>"
    render.call(plain).should eq "<p>x|none|PLAIN</p>"
    render.call(shout).should eq "<p>x|none|SHOUT</p>"
  end
end

private def both_pages : {Azu::Templates, Azu::Templates}
  {filters_page, Azu::Templates.new(["spec/fixtures/compiled_loops"], File.join(Dir.tempdir, "azu_compiled_errors"), hot_reload: true)}
end

private ESCAPE_DATA = {
  "x"    => %(<a href='q'>&amp; "é" ✓</a>),
  "vals" => [Crinja::Value.new(%('"&<>)), Crinja::Value.new("naïve ✓ & ü"), Crinja::Value.new(Crinja::SafeString.new("<b>&amp;</b>")),
             Crinja::Value.new(42), Crinja::Value.new(nil), Crinja::Value.new(Crinja::Undefined.new("w"))],
}

describe "Azu::Templates compiled templates (escape written to the io)" do
  it "prints | e, | escape, | safe and plain values like Crinja, with autoescape on and off" do
    [true, false].each do |escape|
      compiled, crinja = both_pages
      {compiled, crinja}.each(&.autoescape=(escape))
      compiled.render("escape.jinja", ESCAPE_DATA).should eq crinja.render("escape.jinja", ESCAPE_DATA)
    end
    filters_page.render("escape.jinja", ESCAPE_DATA).should start_with "&lt;a href=&#39;q&#39;&gt;&amp;amp; &quot;é&quot; ✓&lt;/a&gt;|"
  end

  it "calls an app's escape, an alias of e, or raises for a disabled escape, like Crinja" do
    {
      ->(f : Crinja::Filter::Library) { f["escape"] = Crinja.filter { "E(#{target})" } },
      ->(f : Crinja::Filter::Library) { f.aliases["e"] = "upper"; f["safe"] = Crinja.filter { "S(#{target})" } },
    }.each do |change|
      outputs = both_pages.map { |page| change.call(page.crinja.filters); page.render("escape.jinja", ESCAPE_DATA) }
      outputs[0].should eq outputs[1]
    end
    both_pages.each do |page|
      page.crinja.filters.disabled << "escape"
      expect_raises(Crinja::SecurityError, "is disabled") { page.render("escape.jinja", ESCAPE_DATA) }
    end
  end

  it "builds no escaped String for | e or an escaping print, nor a ForLoop for an array, nor reads the rule allocating" do
    {"escape.jinja" => 5_000, "plain.txt.j2" => 64, "nested_for.jinja" => 200}.each do |name, limit| # bytes per render
      template = filters_page.load(name).as(Azu::Templates::CompiledTemplate)
      env, io = template.env, IO::Memory.new(100_000)
      data = Crinja::Context.new(bindings: Crinja.variables({"x" => "&" * 10_000, "vals" => [] of String, "rows" => [["<a>", "b"], ["c"]]}))
      render = -> { 1000.times { io.clear; env.with_scope(data) { template.render(io, env) } } }
      render.call
      before = GC.stats.total_bytes
      render.call
      ((GC.stats.total_bytes - before) // 1000).should be < limit
    end
  end

  it "reads the file's autoescape rule on every render, so an in-place change to its lists applies" do
    page = filters_page
    page.render("plain.txt.j2", {"x" => "<b>"}).should eq "<b>"
    page.crinja.config.autoescape.enabled_extensions << "txt"
    page.render("plain.txt.j2", {"x" => "<b>"}).should eq "&lt;b&gt;"
    page.crinja.config.autoescape.enabled_extensions.pop
    page.render("plain.txt.j2", {"x" => "<b>"}).should eq "<b>"
    page.crinja.config.autoescape.disabled_extensions.delete("txt")
    page.render("plain.txt.j2", {"x" => "<b>"}).should eq "&lt;b&gt;"
  end
end
