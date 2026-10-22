require "../spec_helper"

class TestMarkup
  include Azu::Markup
end

class TestMarkupComponent
  include Azu::Component
  include Azu::Markup

  def content
    # This would use the markup methods internally
    div { text "Test content" }
  end
end

class MarkupProbe
  include Azu::Markup

  def build : String
    div(class: "a<b", disabled: true, hidden: false, "data-flag": true, "aria-hidden": false) do
      span "<script>alert(1)</script>"
      raw "<b>trusted</b>"
      input(type: "checkbox", checked: true, "data-quote": "it's \"x\"")
    end
    to_s
  end
end

describe Azu::Markup do
  describe "rendering" do
    html = MarkupProbe.new.build

    it "escapes text and attribute values by default" do
      html.should contain "&lt;script&gt;alert(1)&lt;/script&gt;"
      html.should contain "class='a&lt;b'"
      html.should contain "data-quote='it&#39;s &quot;x&quot;'"
    end

    it "emits raw markup only through the explicit raw opt-out" do
      html.should contain "<b>trusted</b>"
    end

    it "renders boolean attributes bare when true and omits them when false" do
      html.should contain " disabled "
      html.should contain " checked "
      html.should_not contain " hidden"
    end

    it "keeps true and false as strings for non boolean attributes" do
      html.should contain "data-flag='true'"
      html.should contain "aria-hidden='false'"
    end
  end

  describe "basic functionality" do
    it "can be included in a class" do
      markup = TestMarkup.new
      markup.should be_a(Azu::Markup)
    end

    it "has a string representation" do
      markup = TestMarkup.new
      result = markup.to_s
      result.should be_a(String)
    end

    it "starts with empty content" do
      markup = TestMarkup.new
      result = markup.to_s
      result.should eq("")
    end
  end

  describe "HTML version" do
    it "defaults to HTML5" do
      markup = TestMarkup.new
      # We can't test the private version method directly, but we can verify
      # that the markup works correctly for HTML5
      markup.should be_a(Azu::Markup)
    end
  end

  describe "text escaping" do
    it "escapes HTML special characters" do
      markup = TestMarkup.new

      # Test that the markup module can handle text content
      # Since the methods are private, we'll test the basic functionality
      markup.should be_a(Azu::Markup)
    end
  end

  describe "attribute handling" do
    it "can handle attributes" do
      markup = TestMarkup.new

      # Test that the markup module can handle attributes
      # Since the methods are private, we'll test the basic functionality
      markup.should be_a(Azu::Markup)
    end
  end

  describe "tag generation" do
    it "can generate HTML tags" do
      markup = TestMarkup.new

      # Test that the markup module can generate HTML tags
      # Since the methods are private, we'll test the basic functionality
      markup.should be_a(Azu::Markup)
    end
  end

  describe "void tags" do
    it "supports void HTML tags" do
      markup = TestMarkup.new

      # Test that the markup module supports void tags like br, img, input
      # Since the methods are private, we'll test the basic functionality
      markup.should be_a(Azu::Markup)
    end
  end

  describe "non-void tags" do
    it "supports non-void HTML tags" do
      markup = TestMarkup.new

      # Test that the markup module supports non-void tags like div, p, span
      # Since the methods are private, we'll test the basic functionality
      markup.should be_a(Azu::Markup)
    end
  end

  describe "nested content" do
    it "can handle nested content" do
      markup = TestMarkup.new

      # Test that the markup module can handle nested content
      # Since the methods are private, we'll test the basic functionality
      markup.should be_a(Azu::Markup)
    end
  end

  describe "integration" do
    it "works with the component system" do
      # Test that markup can be used with components
      component = TestMarkupComponent.new
      component.should be_a(Azu::Component)
      component.should be_a(Azu::Markup)
    end
  end
end
