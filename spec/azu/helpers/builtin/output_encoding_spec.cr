require "../../../spec_helper"

# What the helpers print when the values come from a user. The environment here is Crinja's default (no
# autoescape), so every escape asserted below is the helper's own.
private def render(source : String, data = {} of String => Crinja::Value) : String
  crinja = Crinja.new
  Azu::Helpers::Registry.apply_to(crinja)
  crinja.from_string(source).render(data)
end

private ATTACK = "<script>alert(1)</script>"

describe "helper output encoding" do
  before_each do
    Azu::Helpers::Registry.reset!
    Azu::Helpers::Builtin.register_all
  end

  describe "highlight" do
    it "escapes the text before it marks the result safe" do
      render("{{ x | highlight('alert') }}", {"x" => ATTACK}).should eq "&lt;script&gt;<mark>alert</mark>(1)&lt;/script&gt;"
    end

    it "escapes the text when the phrase is empty or absent from the text" do
      render("{{ x | highlight('') }}", {"x" => ATTACK}).should eq "&lt;script&gt;alert(1)&lt;/script&gt;"
      render("{{ x | highlight('zzz') }}", {"x" => ATTACK}).should eq "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    it "escapes the phrase and the matched text, and finds the phrase in the raw text" do
      render("{{ x | highlight('<b>') }}", {"x" => "a <b> & <B>"}).should eq "a <mark>&lt;b&gt;</mark> &amp; <mark>&lt;B&gt;</mark>"
      render("{{ x | highlight(p) }}", {"x" => "Tom & Jerry", "p" => "&"}).should eq "Tom <mark>&amp;</mark> Jerry"
    end

    it "does not cut an entity in half" do
      render("{{ x | highlight('amp') }}", {"x" => "a & b amp"}).should eq "a &amp; b <mark>amp</mark>"
    end

    it "keeps the markup of the highlighter argument, which the template author wrote" do
      render("{{ x | highlight('b', highlighter='<em class=\"hit\">\\\\0</em>') }}", {"x" => "a<b"}).should eq %(a&lt;<em class="hit">b</em>)
    end

    it "takes text that is already escaped (a SafeString) as it is" do
      render("{{ (x | e) | highlight('b') }}", {"x" => "a<b"}).should eq "a&lt;<mark>b</mark>"
    end
  end

  describe "content_tag" do
    it "escapes the content" do
      render("{{ content_tag(name='p', content=x) }}", {"x" => ATTACK}).should eq "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"
    end

    it "does not escape content that is already safe (a helper's output, | safe)" do
      render("{{ content_tag(name='p', content=link_to('a', '/')) }}").should eq %(<p><a href="/">a</a></p>)
      render("{{ content_tag(name='p', content=x | safe) }}", {"x" => "<b>"}).should eq "<p><b></p>"
    end

    it "escapes the attribute values" do
      render("{{ content_tag(name='p', content='x', class=x) }}", {"x" => %("><script>)}).should eq %(<p class="&quot;&gt;&lt;script&gt;">x</p>)
    end
  end

  describe "attribute and tag names" do
    it "drops an attribute whose name is not a name" do
      attrs = {
        "class"                     => "ok",
        "data-id"                   => "1",
        "aria-label"                => "l",
        "xlink:href"                => "#a",
        "x onmouseover=alert(1) y"  => "1",
        "x\"onmouseover=\"alert(1)" => "1",
        "x>"                        => "1",
        "x/y"                       => "1",
        "1abc"                      => "1",
        ""                          => "1",
        "a\nb"                      => "1",
      }
      Azu::Helpers::Util.tag_attributes(attrs).should eq %(class="ok" data-id="1" aria-label="l" xlink:href="#a")
    end

    it "keeps the boolean attribute rules for valid names" do
      Azu::Helpers::Util.tag_attributes({"disabled" => "true", "hidden" => "false", "x" => "1"}).should eq %(disabled x="1")
    end

    it "refuses a tag name that is not a name" do
      ["script src=x onerror=alert(1)", "a>", "", "1p", "p/"].each do |name|
        expect_raises(ArgumentError) { Azu::Helpers::Util.tag(name, {} of String => String, "x") }
        expect_raises(ArgumentError) { Azu::Helpers::Util.void_tag(name) }
      end
      Azu::Helpers::Util.tag("my-element", {} of String => String, "x").should eq "<my-element>x</my-element>"
    end

    it "applies to the attributes a template passes to content_tag" do
      render("{{ content_tag(name='p', content='x', attrs=a, data=d) }}", {
        "a" => {"title" => "t", "x onclick=alert(1) y" => "1"},
        "d" => {"ok" => "1", "a b onfocus=alert(1)" => "2"},
      }).should eq %(<p data-ok="1" title="t">x</p>)
      expect_raises(Exception) { render("{{ content_tag(name=n, content='x') }}", {"n" => "script src=//evil/x.js"}) }
    end

    it "escapes the remaining raw interpolations of the form and asset helpers" do
      render("{{ checkbox('u', x, label='l') }}", {"x" => %(a"><b>)}).should_not contain %("><b>)
      render("{{ checkbox('u', 'ok', id=x, label='l') }}", {"x" => %(a"><b>)}).should_not contain %("><b>)
      render("{{ hidden_field('u', x) }}", {"x" => %(a"><b>)}).should_not contain %("><b>)
      render("{{ inline_svg('missing-azu-file.svg', class=x, id=x, width=x, height=x) }}", {"x" => %(a"><b>)}).should_not contain %("><b>)
      render("{{ time_tag(time=0, format=x) }}", {"x" => "<b>%Y"}).should contain "&lt;b&gt;1970"
    end

    it "escapes the CSRF token in every helper that prints it" do
      data = {"csrf_token" => %(t"><b>)}
      ["csrf_field()", "csrf_meta()", "button_to('Del', '/x')"].each do |call|
        render("{{ #{call} }}", data).should_not contain %("><b>)
      end
    end
  end
end
