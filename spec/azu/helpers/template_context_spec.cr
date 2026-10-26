require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Helpers::TemplateContext do
  it "gives csrf_tag and csrf_metatag to autoescaped templates as markup" do
    context, _ = create_context
    vars = Azu::Helpers::TemplateContext.new(context).to_template_vars
    vars["csrf_tag"].raw.should be_a Crinja::SafeString
    vars["csrf_metatag"].raw.should be_a Crinja::SafeString

    dir = File.join(Dir.tempdir, "azu_ctx_#{Random::Secure.hex(6)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "page.jinja"), "{{ csrf_tag }}{{ csrf_metatag }}|{{ csrf_token }}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      out = templates.load("page.jinja").render(vars)
      out.should contain "<input"
      out.should contain "<meta"
      out.should_not contain "&lt;"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "keeps csrf_tag and csrf_metatag Strings on the endpoint" do
    Azu::Handler::CSRF.tag(create_context[0]).should be_a String
    Azu::Handler::CSRF.metatag(create_context[0]).should be_a String
  end
end
