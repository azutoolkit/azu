require "../spec_helper"

describe Azu::I18nConfiguration do
  it "does not touch the process-wide I18n when it is built" do
    default = Azu::Helpers::I18n.default_locale
    ENV["I18N_LOAD_PATH"] = "spec/fixtures/locales"
    ENV["I18N_DEFAULT_LOCALE"] = "es"
    begin
      Azu::I18nConfiguration.new
      Azu::Configuration.new
      Azu::App.new
      Azu::Helpers::I18n.default_locale.should eq default
    ensure
      ENV.delete("I18N_LOAD_PATH")
      ENV.delete("I18N_DEFAULT_LOCALE")
    end
  end

  it "applies its settings to the process-wide I18n when asked to" do
    default = Azu::Helpers::I18n.default_locale
    config = Azu::I18nConfiguration.new
    config.load_path = ["spec/fixtures/locales"]
    config.default_locale = "es"
    begin
      config.apply
      Azu::Helpers::I18n.default_locale.should eq "es"
    ensure
      Azu::Helpers::I18n.default_locale = default
      Azu::Helpers::I18n.load_path = ["locales"]
    end
  end

  it "does not overwrite an explicit Helpers::I18n.configure with its defaults" do
    default = Azu::Helpers::I18n.default_locale
    Azu::Helpers::I18n.configure { |config| config.default_locale = "es" }
    begin
      app = Azu::App.new
      app.config.i18n.load_path = ["spec/fixtures/locales"]
      app.server
      Azu::Helpers::I18n.default_locale.should eq "es"
    ensure
      Azu::Helpers::I18n.configure { |config| config.default_locale = default }
    end
  end
end
