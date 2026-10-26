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
end
