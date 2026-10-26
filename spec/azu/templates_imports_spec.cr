require "../spec_helper"
require "../support/template_helpers"

module TemplatesImportsSpec
  # A page rendered with `view`, as an endpoint's response renders it.
  struct Page
    include Azu::Templates::Renderable

    def initialize(@template : String, @data = {} of String => String)
    end

    def render : String
      view @template, @data
    end
  end

  MACROS = "{% set sep = '|' %}{% macro inner() %}I{% endmacro %}{% macro outer(a) %}<{{ inner() }}{{ a }}{{ sep }}>{% endmacro %}"
end

describe "Azu::Templates imports" do
  {
    "from"      => %({% from "m.jinja" import outer %}{{ outer(1) }}),
    "import as" => %({% import "m.jinja" as m %}{{ m.outer(1) }}),
  }.each do |form, page|
    it "let a macro imported with #{form} call a sibling macro and read a set of its file" do
      with_compiled_templates({"m.jinja" => TemplatesImportsSpec::MACROS, "page.jinja" => page}) do
        TemplatesImportsSpec::Page.new("page.jinja").render.should eq "<I1|>"
      end
    end
  end

  {
    "import"      => %({% import "m.txt" %}{{ v }}),
    "from import" => %({% from "m.txt" import m %}{{ v }}),
  }.each do |form, page|
    it "keep escaping the page after an #{form} of a plain text template" do
      with_compiled_templates({"m.txt" => "{% macro m() %}x{% endmacro %}", "page.jinja" => page}) do
        TemplatesImportsSpec::Page.new("page.jinja", {"v" => "<b>"}).render.should eq "&lt;b&gt;"
      end
    end
  end
end
