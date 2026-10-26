require "../../spec_helper"
require "../../support/integration_helpers"

include IntegrationHelpers

describe Azu::Helpers::TemplateContext do
  it "gives csrf_tag and csrf_metatag to autoescaped templates as markup" do
    Azu::Handler::CSRF.new(secret_key: "test-secret")
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

describe "CSRF values in templates" do
  it "carry the token of the response's cookie" do
    Azu::Handler::CSRF.configure { |csrf| csrf.secret_key = "test-secret" }
    context, _ = create_context
    vars = Azu::Helpers::TemplateContext.new(context).to_template_vars

    token = context.response.cookies["csrf_token"].value
    vars["csrf_token"].to_s.should eq token
    vars["csrf_tag"].to_s.should contain token
    vars["csrf_metatag"].to_s.should contain token
  ensure
    Azu::Handler::CSRF.reset_default!
  end

  # An app without CSRF protection renders its pages in production without CSRF_SECRET and sets no cookie.
  it "are left out while no CSRF handler has been built" do
    saved = {ENV["CRYSTAL_ENV"]?, ENV["CSRF_SECRET"]?}
    ENV["CRYSTAL_ENV"] = "production"
    ENV.delete("CSRF_SECRET")
    Azu::Env.reset_generated_secrets!
    Azu::Handler::CSRF.reset_default!
    begin
      context, _ = create_context
      vars = Azu::Helpers::TemplateContext.new(context).to_template_vars

      vars.has_key?("csrf_token").should be_false
      vars.has_key?("csrf_tag").should be_false
      vars.has_key?("csrf_metatag").should be_false
      context.response.cookies["csrf_token"]?.should be_nil
    ensure
      saved[0] ? (ENV["CRYSTAL_ENV"] = saved[0].not_nil!) : ENV.delete("CRYSTAL_ENV")
      saved[1] ? (ENV["CSRF_SECRET"] = saved[1].not_nil!) : ENV.delete("CSRF_SECRET")
      Azu::Env.reset_generated_secrets!
    end
  end
end
