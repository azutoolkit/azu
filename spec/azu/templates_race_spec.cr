require "../spec_helper"

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
  Azu::Helpers::Registry.register_function(:race_pause, Crinja.function { sleep 5.milliseconds; "" })

  # Templates parsed once (production) from a fresh directory holding `files`, rendered with `view` under `config`.
  def self.with_templates(files : Hash(String, String), & : Azu::Configuration ->) : Nil
    dir = File.tempname("azu_race")
    Dir.mkdir_p(dir)
    files.each { |name, source| File.write(File.join(dir, name), source) }
    config = Azu::Configuration.new
    config.template_hot_reload = false
    config.templates.path = dir
    Azu.with_config(config) { yield config }
  ensure
    FileUtils.rm_rf(dir) if dir
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
    TemplatesRaceSpec.with_templates({"race.jinja" => "{{ name }}-{{ race_pause() }}{{ name }}"}) do |config|
      results = Channel(String).new

      {"A", "B"}.each do |name|
        spawn { Azu.with_config(config) { results.send TemplatesRaceSpec::Page.new("race.jinja", {"name" => name}).render } }
      end

      Array.new(2) { results.receive }.sort.should eq ["A-A", "B-B"]
    end
  end

  it "leaves no request's variables behind when a direct render overlaps a view" do
    files = {"secret.jinja" => "{{ secret }}{{ race_pause() }}", "direct.jinja" => "{{ race_pause() }}{{ x }}", "later.jinja" => "[{{ secret }}]"}
    TemplatesRaceSpec.with_templates(files) do |config|
      env = config.templates.crinja
      done = Channel(Nil).new

      spawn { Azu.with_config(config) { TemplatesRaceSpec::Page.new("secret.jinja", {"secret" => "A-SECRET"}).render }; done.send nil }
      spawn { sleep 1.millisecond; config.templates.load("direct.jinja").render({"x" => 1}); done.send nil }
      2.times { done.receive }

      TemplatesRaceSpec::Page.new("later.jinja").render.should eq "[]"
      env.context.should be(env.global_context)
      TemplatesRaceSpec.within_a_second { env.context.same?(env.global_context).to_s }.should eq "true"
    end
  end

  it "lets a helper wait for a render in another fiber" do
    TemplatesRaceSpec.with_templates({"outer.jinja" => "<{{ race_elsewhere() }}>", "inner.jinja" => "inner"}) do |config|
      templates = config.templates
      Azu::Helpers::Registry.register_function(:race_elsewhere, Crinja.function {
        TemplatesRaceSpec.within_a_second { templates.render("inner.jinja") }
      })

      TemplatesRaceSpec::Page.new("outer.jinja").render.should eq "<inner>"
    end
  end

  it "renders a page whose helper reads a fragment another request is caching" do
    files = {"sidebar.jinja" => "<aside>{{ n }}</aside>", "page.jinja" => "{{ race_pause() }}{{ race_sidebar() }}"}
    TemplatesRaceSpec.with_templates(files) do |config|
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
