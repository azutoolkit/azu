require "../../spec_helper"

describe Azu::Helpers::Registry do
  before_each do
    Azu::Helpers::Registry.reset!
  end

  describe ".register_filter" do
    it "registers a filter by name" do
      filter = Crinja.filter(:test_upper) { target.to_s.upcase }
      Azu::Helpers::Registry.register_filter(:test_upper, filter)
      Azu::Helpers::Registry.filters[:test_upper].should_not be_nil
    end

    it "overwrites existing filter with same name" do
      filter1 = Crinja.filter(:overwrite_test) { "first" }
      filter2 = Crinja.filter(:overwrite_test) { "second" }

      Azu::Helpers::Registry.register_filter(:overwrite_test, filter1)
      Azu::Helpers::Registry.register_filter(:overwrite_test, filter2)

      Azu::Helpers::Registry.filters[:overwrite_test].should eq filter2
    end
  end

  describe ".register_function" do
    it "registers a function by name" do
      func = Crinja.function(:test_func) { "hello" }
      Azu::Helpers::Registry.register_function(:test_func, func)
      Azu::Helpers::Registry.functions[:test_func].should_not be_nil
    end
  end

  describe ".register_global" do
    it "registers a global variable" do
      Azu::Helpers::Registry.register_global(:app_name, "Test App")
      Azu::Helpers::Registry.globals[:app_name].should eq "Test App"
    end

    it "registers global with Crinja::Value" do
      value = Crinja::Value.new(42)
      Azu::Helpers::Registry.register_global(:answer, value)
      Azu::Helpers::Registry.globals[:answer].should eq value
    end
  end

  describe ".register_test" do
    it "registers a test by name" do
      test = Crinja.test(:is_positive) { target.to_i > 0 }
      Azu::Helpers::Registry.register_test(:is_positive, test)
      Azu::Helpers::Registry.tests[:is_positive].should_not be_nil
    end
  end

  describe ".apply_to" do
    it "applies all registered helpers to a Crinja environment" do
      filter = Crinja.filter(:spec_upper) { target.to_s.upcase }
      Azu::Helpers::Registry.register_filter(:spec_upper, filter)

      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'hello' | spec_upper }}")
      template.render.should eq "HELLO"
    end

    it "applies global variables to template context" do
      Azu::Helpers::Registry.register_global(:site_title, "My Site")

      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ site_title }}")
      template.render.should eq "My Site"
    end

    it "applies functions to template" do
      func = Crinja.function(:greet) { "Hello, World!" }
      Azu::Helpers::Registry.register_function(:greet, func)

      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ greet() }}")
      template.render.should eq "Hello, World!"
    end

    it "only applies helpers once to the same environment" do
      crinja = Crinja.new

      Azu::Helpers::Registry.apply_to(crinja)
      first_call = Azu::Helpers::Registry.applied_to?(crinja)

      Azu::Helpers::Registry.apply_to(crinja)
      second_call = Azu::Helpers::Registry.applied_to?(crinja)

      first_call.should be_true
      second_call.should be_true
    end
  end

  describe ".reset!" do
    it "clears all registered helpers" do
      Azu::Helpers::Registry.register_global(:test, "value")
      Azu::Helpers::Registry.reset!
      Azu::Helpers::Registry.globals.empty?.should be_true
    end
  end
end
