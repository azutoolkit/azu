require "../spec_helper"

module TemplatesRaceSpec
  # A page rendered with `view`, as an endpoint's response renders it.
  struct NamePage
    include Azu::Templates::Renderable

    def initialize(@name : String)
    end

    def render : String
      view "race.jinja", {"name" => @name}
    end
  end
end

describe "Azu::Templates under concurrent requests" do
  it "keeps each render's variables when a helper yields the fiber mid-render" do
    # A helper that does IO (a query, a cache read) lets another request's fiber run before the render finishes
    Azu::Helpers::Registry.register_function(:yield_fiber, Crinja.function { sleep 1.millisecond; "" })
    dir = File.tempname("azu_race")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "race.jinja"), "{{ name }}-{{ yield_fiber() }}{{ name }}")
    begin
      config = Azu::Configuration.new
      config.template_hot_reload = false
      config.templates.path = dir
      results = Channel(String).new

      {"A", "B"}.each do |name|
        spawn { Azu.with_config(config) { results.send TemplatesRaceSpec::NamePage.new(name).render } }
      end

      Array.new(2) { results.receive }.sort.should eq ["A-A", "B-B"]
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
