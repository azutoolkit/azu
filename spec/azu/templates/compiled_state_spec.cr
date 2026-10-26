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
