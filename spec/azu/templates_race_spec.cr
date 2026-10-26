require "../spec_helper"
require "../support/template_helpers"

module TemplatesRaceSpec
  # A page rendered with `view`, as an endpoint's response renders it.
  struct Page
    include Azu::Templates::Renderable

    def initialize(@template : String, @data = {} of String => String)
    end

    def render : String
      view @template, @data
    end
  end

  # A helper that does IO (a query, a cache read) lets another request's fiber run before the render finishes.
  # Registered by each example that uses it: other specs reset the registry.
  def self.register_pause : Nil
    Azu::Helpers::Registry.register_function(:race_pause, Crinja.function { sleep 5.milliseconds; "" })
  end

  # What the block returns, run in another fiber, or "timed out": a deadlock fails the example instead of the suite.
  def self.within_a_second(&block : -> String) : String
    result = Channel(String).new(1)
    spawn { result.send block.call }
    select
    when value = result.receive then value
    when timeout(1.second) then "timed out"
    end
  end
end

describe "Azu::Templates under concurrent requests" do
  it "keeps each render's variables when a helper yields the fiber mid-render" do
    TemplatesRaceSpec.register_pause
    with_preloaded_templates({"race.jinja" => "{{ name }}-{{ race_pause() }}{{ name }}"}) do |config|
      results = Channel(String).new(2)

      {"A", "B"}.each do |name|
        spawn { Azu.with_config(config) { results.send TemplatesRaceSpec::Page.new("race.jinja", {"name" => name}).render } }
      end

      Array.new(2) { TemplatesRaceSpec.within_a_second { results.receive } }.sort.should eq ["A-A", "B-B"]
    end
  end

  it "leaves no request's variables behind when a direct render overlaps a view" do
    files = {"secret.jinja" => "{{ secret }}{{ race_pause() }}", "direct.jinja" => "{{ race_pause() }}{{ x }}", "later.jinja" => "[{{ secret }}]"}
    TemplatesRaceSpec.register_pause
    with_preloaded_templates(files) do |config|
      env = config.templates.crinja
      done = Channel(String).new(2)

      spawn { done.send Azu.with_config(config) { TemplatesRaceSpec::Page.new("secret.jinja", {"secret" => "A-SECRET"}).render } }
      spawn { sleep 1.millisecond; done.send config.templates.load("direct.jinja").render({"x" => 1}) }
      2.times { TemplatesRaceSpec.within_a_second { done.receive } }

      TemplatesRaceSpec::Page.new("later.jinja").render.should eq "[]"
      env.context.should be(env.global_context)
      TemplatesRaceSpec.within_a_second { env.context.same?(env.global_context).to_s }.should eq "true"
    end
  end

  it "lets a helper wait for a render in another fiber" do
    with_preloaded_templates({"outer.jinja" => "<{{ race_elsewhere() }}>", "inner.jinja" => "inner"}) do |config|
      templates = config.templates
      elsewhere = Crinja.function { TemplatesRaceSpec.within_a_second { templates.render("inner.jinja") } }
      Azu::Helpers::Registry.register_function(:race_elsewhere, elsewhere)

      TemplatesRaceSpec::Page.new("outer.jinja").render.should eq "<inner>"
    end
  end

  it "renders a page whose helper reads a fragment another request is caching" do
    files = {"sidebar.jinja" => "<aside>{{ n }}</aside>", "page.jinja" => "{{ race_pause() }}{{ race_sidebar() }}"}
    TemplatesRaceSpec.register_pause
    with_preloaded_templates(files) do |config|
      key = "race-sidebar-#{Random::Secure.hex(4)}"
      # An endpoint caching a rendered fragment (`Azu.cache.fetch(key) { view(...) }`), and a page helper reading it
      fragment = -> { config.cache.fetch(key) { config.templates.render("sidebar.jinja", {"n" => 1}) } }
      Azu::Helpers::Registry.register_function(:race_sidebar, Crinja.function { Crinja::SafeString.new(fragment.call) })
      page = Channel(String).new(1)

      spawn { page.send config.templates.render("page.jinja") }
      sleep 1.millisecond

      TemplatesRaceSpec.within_a_second { fragment.call }.should eq "<aside>1</aside>"
      TemplatesRaceSpec.within_a_second { page.receive }.should eq "<aside>1</aside>"
    end
  end
end

describe "Azu::Templates between requests" do
  it "does not hand a macro one request defined to the next" do
    files = {"macros.jinja" => "{% if admin %}{% macro panel(note=secret) %}[{{ note }}]{% endmacro %}{% endif %}",
             "page.jinja"   => %({% from "macros.jinja" import panel %}{{ panel() }})}
    with_preloaded_templates(files) do
      TemplatesRaceSpec::Page.new("page.jinja", {"admin" => "yes", "secret" => "A-SECRET"}).render.should eq "[A-SECRET]"

      # This request defines no macro: the import finds none, not the previous request's (and its secret)
      expect_raises(Crinja::Error, /Unknown import `panel`/) { TemplatesRaceSpec::Page.new("page.jinja").render }
    end
  end

  it "keeps what an include without context sets out of later renders" do
    files = {"set.jinja" => "{% set banner = 'leaked' %}", "page.jinja" => %({% include "set.jinja" without context %}a),
             "later.jinja" => "b:{{ banner }}"}
    with_preloaded_templates(files) do
      TemplatesRaceSpec::Page.new("page.jinja").render.should eq "a"
      TemplatesRaceSpec::Page.new("later.jinja").render.should eq "b:"
    end
  end

  it "starts a render a helper makes from the global context, not from the outer request's" do
    # A fragment a helper renders may be cached and served to everyone (`Azu.cache.fetch(key) { ... }`)
    with_preloaded_templates({"page.jinja" => "{{ race_fragment() }}", "frag.jinja" => "[{{ secret }}]"}) do |config|
      templates = config.templates
      fragment = Crinja.function { templates.render("frag.jinja") + TemplatesRaceSpec::Page.new("frag.jinja").render }
      Azu::Helpers::Registry.register_function(:race_fragment, fragment)

      TemplatesRaceSpec::Page.new("page.jinja", {"secret" => "OUTER"}).render.should eq "[][]"
    end
  end
end
