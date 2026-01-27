require "../../../spec_helper"

describe "HTML Helpers" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin::HtmlHelpers.register
  end

  describe "safe_html filter" do
    it "marks content as safe (no escaping)" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '<b>bold</b>' | safe_html }}")
      result = template.render

      result.should eq "<b>bold</b>"
    end

    it "allows HTML to pass through without escaping" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '<script>alert(1)</script>' | safe_html }}")
      result = template.render

      result.should eq "<script>alert(1)</script>"
    end
  end

  describe "simple_format filter" do
    it "wraps text in paragraph tags" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World' | simple_format }}")
      result = template.render

      result.should contain "<p>"
      result.should contain "Hello World"
      result.should contain "</p>"
    end

    it "converts double newlines to new paragraphs" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Para 1\n\nPara 2' | simple_format }}")
      result = template.render

      result.should contain "<p>Para 1</p>"
      result.should contain "<p>Para 2</p>"
    end

    it "converts single newlines to br tags" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Line 1\nLine 2' | simple_format }}")
      result = template.render

      result.should contain "Line 1<br>Line 2"
    end

    it "escapes HTML in content" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '<script>alert(1)</script>' | simple_format }}")
      result = template.render

      result.should contain "&lt;script&gt;"
      result.should_not contain "<script>"
    end

    it "supports custom wrapper tag" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello' | simple_format(tag='div') }}")
      result = template.render

      result.should contain "<div>"
      result.should contain "</div>"
    end
  end

  describe "highlight filter" do
    it "highlights matching phrase" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World' | highlight('World') }}")
      result = template.render

      result.should contain "<mark>World</mark>"
    end

    it "highlights case-insensitively" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello WORLD' | highlight('world') }}")
      result = template.render

      result.should contain "<mark>WORLD</mark>"
    end

    it "supports custom highlighter" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World' | highlight('World', highlighter='<em>\\\\0</em>') }}")
      result = template.render

      result.should contain "<em>World</em>"
    end

    it "returns original text when phrase is empty" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World' | highlight('') }}")
      result = template.render

      result.should eq "Hello World"
    end

    it "highlights multiple occurrences" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'foo bar foo' | highlight('foo') }}")
      result = template.render

      result.scan("<mark>foo</mark>").size.should eq 2
    end
  end

  describe "truncate_html filter" do
    it "truncates text content" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World' | truncate_html(8) }}")
      result = template.render

      result.should eq "Hello..."
    end

    it "returns original if shorter than length" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello' | truncate_html(100) }}")
      result = template.render

      result.should eq "Hello"
    end

    it "supports custom omission" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World' | truncate_html(8, omission='…') }}")
      result = template.render

      result.should eq "Hello W…"
    end
  end

  describe "strip_tags filter" do
    it "removes HTML tags" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '<p>Hello <b>World</b></p>' | strip_tags }}")
      result = template.render

      result.should eq "Hello World"
    end

    it "handles self-closing tags" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello<br/>World' | strip_tags }}")
      result = template.render

      result.should eq "HelloWorld"
    end

    it "handles nested tags" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '<div><p><span>Text</span></p></div>' | strip_tags }}")
      result = template.render

      result.should eq "Text"
    end
  end

  describe "word_wrap filter" do
    it "wraps text at specified width" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World Test' | word_wrap(line_width=10) }}")
      result = template.render

      result.should contain "\n"
    end

    it "supports custom break character" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Hello World Test' | word_wrap(line_width=10, break_char='<br>') }}")
      result = template.render

      result.should contain "<br>"
    end
  end

  describe "auto_link filter" do
    it "converts URLs to links" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Visit https://example.com' | auto_link }}")
      result = template.render

      result.should contain "<a href=\"https://example.com\""
      result.should contain ">https://example.com</a>"
    end

    it "converts email addresses to mailto links" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Email test@example.com' | auto_link }}")
      result = template.render

      result.should contain "<a href=\"mailto:test@example.com\""
      result.should contain ">test@example.com</a>"
    end

    it "adds security attributes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ 'Visit https://example.com' | auto_link }}")
      result = template.render

      result.should contain "rel=\"noopener noreferrer\""
    end

    it "escapes HTML when sanitize is true" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ '<script>https://example.com</script>' | auto_link }}")
      result = template.render

      result.should contain "&lt;script&gt;"
    end
  end

  describe "content_tag function" do
    it "generates a content tag" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ content_tag(name='div', content='Hello') }}")
      result = template.render

      result.should eq "<div>Hello</div>"
    end

    it "supports CSS class" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ content_tag(name='div', content='Hello', class='container') }}")
      result = template.render

      result.should contain "class=\"container\""
    end

    it "supports id attribute" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ content_tag(name='div', content='Hello', id='main') }}")
      result = template.render

      result.should contain "id=\"main\""
    end

    it "supports data attributes" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ content_tag(name='div', content='Hello', data={'action': 'click'}) }}")
      result = template.render

      result.should contain "data-action=\"click\""
    end

    it "defaults to div tag" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ content_tag(content='Hello') }}")
      result = template.render

      result.should contain "<div>"
      result.should contain "</div>"
    end
  end

  describe "cycle function" do
    it "returns first value from the list" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ cycle(values=['odd', 'even']) }}")
      result = template.render

      result.should eq "odd"
    end

    it "returns empty string for empty values" do
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)

      template = crinja.from_string("{{ cycle(values=[]) }}")
      result = template.render

      result.should eq ""
    end
  end
end
