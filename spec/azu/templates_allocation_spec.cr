require "../spec_helper"
require "../../benchmark/micro/harness"

module TemplatesAllocationSpec
  VARIABLES_SOURCE = "{{ a }}{{ b }}{{ c }}{{ d }}{{ e }}"

  # A page rendered with `view`, as an endpoint's response renders it.
  struct VariablesPage
    include Azu::Templates::Renderable

    def initialize(@data : Hash(String, Crinja::Value))
    end

    def render : String
      view "variables.jinja", @data
    end
  end

  # Templates parsed once (production) from a fresh directory holding `files`.
  def self.with_templates(files : Hash(String, String), & : Azu::Configuration ->) : Nil
    dir = File.tempname("azu_templates_allocation")
    Dir.mkdir_p(dir)
    files.each { |name, source| File.write(File.join(dir, name), source) }
    config = Azu::Configuration.new
    config.template_hot_reload = false
    config.templates.path = dir
    Azu.with_config(config) { yield config }
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

describe "view allocations" do
  {% if flag?(:preview_mt) %}
    # GC.stats.total_bytes counts every thread
    pending "hands its variables to the render without copying them"
  {% else %}
    it "hands its variables to the render without copying them" do
      data = {"a" => Crinja::Value.new(1), "b" => Crinja::Value.new("two"), "c" => Crinja::Value.new(3), "d" => Crinja::Value.new(4), "e" => Crinja::Value.new(5)}
      TemplatesAllocationSpec.with_templates({"variables.jinja" => TemplatesAllocationSpec::VARIABLES_SOURCE}) do |config|
        page = TemplatesAllocationSpec::VariablesPage.new(data)
        template = config.templates.load("variables.jinja")
        page.render.should eq "1two345"

        through_view = HotPath.bytes_per_call { page.render }
        # What a render needs at least: its variables in a context below the environment's, then the template
        in_place = HotPath.bytes_per_call do
          context = Crinja::Context.new(config.templates.crinja.context)
          data.each { |key, value| context[key] = value }
          template.render(context)
        end

        # The hash view builds (its object is ~64 B) is the only difference: it is not copied again for Crinja
        (through_view - in_place).should be <= 80
      end
    end
  {% end %}
end
