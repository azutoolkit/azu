require "../../spec_helper"

describe Azu::Helpers::I18n do
  # Create test locale files before running specs
  before_all do
    test_locales_dir = "spec/fixtures/locales"
    Dir.mkdir_p(test_locales_dir) unless Dir.exists?(test_locales_dir)

    # Create English locale file
    File.write("#{test_locales_dir}/en.yml", <<-YAML)
    en:
      welcome:
        title: "Welcome!"
        greeting: "Hello, %{name}!"
      users:
        count:
          zero: "No users"
          one: "1 user"
          other: "%{count} users"
      date:
        formats:
          short: "%b %d"
          long: "%B %d, %Y"
      simple_key: "Simple value"
    YAML

    # Create Spanish locale file
    File.write("#{test_locales_dir}/es.yml", <<-YAML)
    es:
      welcome:
        title: "Bienvenido!"
        greeting: "Hola, %{name}!"
      simple_key: "Valor simple"
    YAML
  end

  before_each do
    Azu::Helpers::I18n.configure do |config|
      config.load_path = ["spec/fixtures/locales"]
      config.default_locale = "en"
      config.available_locales = ["en", "es"]
      config.raise_on_missing = false
    end
  end

  describe ".t" do
    it "translates a simple key" do
      Azu::Helpers::I18n.t("welcome.title").should eq "Welcome!"
    end

    it "translates a nested key" do
      Azu::Helpers::I18n.t("simple_key").should eq "Simple value"
    end

    it "supports interpolation" do
      Azu::Helpers::I18n.t("welcome.greeting", name: "John").should eq "Hello, John!"
    end

    it "returns default when key is missing" do
      result = Azu::Helpers::I18n.t("missing.key", default: "Fallback")
      result.should eq "Fallback"
    end

    it "returns missing key marker when no default provided" do
      result = Azu::Helpers::I18n.t("nonexistent.key")
      result.should contain "nonexistent.key"
    end
  end

  describe "pluralization" do
    it "uses zero form for count of 0" do
      Azu::Helpers::I18n.t("users.count", count: 0).should eq "No users"
    end

    it "uses singular for count of 1" do
      Azu::Helpers::I18n.t("users.count", count: 1).should eq "1 user"
    end

    it "uses plural for count > 1" do
      Azu::Helpers::I18n.t("users.count", count: 5).should eq "5 users"
    end
  end

  describe ".locale" do
    it "returns default locale initially" do
      Azu::Helpers::I18n.locale.should eq "en"
    end

    it "can be changed" do
      Azu::Helpers::I18n.locale = "es"
      Azu::Helpers::I18n.locale.should eq "es"
      Azu::Helpers::I18n.locale = "en" # Reset
    end
  end

  describe ".with_locale" do
    it "temporarily changes locale within block" do
      Azu::Helpers::I18n.locale = "en"

      result = Azu::Helpers::I18n.with_locale("es") do
        Azu::Helpers::I18n.t("welcome.title")
      end

      result.should eq "Bienvenido!"
      Azu::Helpers::I18n.locale.should eq "en"
    end
  end

  describe ".available_locales" do
    it "returns configured available locales" do
      locales = Azu::Helpers::I18n.available_locales
      locales.should contain "en"
      locales.should contain "es"
    end
  end

  describe ".exists?" do
    it "returns true for existing key" do
      Azu::Helpers::I18n.exists?("welcome.title").should be_true
    end

    it "returns false for missing key" do
      Azu::Helpers::I18n.exists?("nonexistent.key").should be_false
    end
  end

  describe ".locale_name" do
    it "returns display name for known locales" do
      Azu::Helpers::I18n.locale_name("en").should eq "English"
      Azu::Helpers::I18n.locale_name("es").should eq "Spanish"
    end

    it "returns uppercase code for unknown locales" do
      Azu::Helpers::I18n.locale_name("xx").should eq "XX"
    end
  end

  describe ".l" do
    it "localizes a date with short format" do
      date = Time.utc(2024, 1, 15)
      result = Azu::Helpers::I18n.l(date, format: "date.formats.short")
      result.should eq "Jan 15"
    end

    it "localizes a date with long format" do
      date = Time.utc(2024, 1, 15)
      result = Azu::Helpers::I18n.l(date, format: "date.formats.long")
      result.should eq "January 15, 2024"
    end

    it "uses default format when not found" do
      date = Time.utc(2024, 1, 15, 10, 30, 0)
      result = Azu::Helpers::I18n.l(date, format: "nonexistent.format")
      # Should use default ISO format
      result.should contain "2024"
    end
  end
end
