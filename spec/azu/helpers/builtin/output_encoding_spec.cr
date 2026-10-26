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

  describe "URL attributes" do
    unsafe = [
      "javascript:alert(1)", "JavaScript:alert(1)", "JAVASCRIPT:alert(1)", "  javascript:alert(1)", "\tjavascript:alert(1)",
      "java\tscript:alert(1)", "java\nscript:alert(1)", "java\r\nscript:alert(1)", "\u0001javascript:alert(1)", "\u0000javascript:alert(1)",
      "jav ascript:alert(1)", "javascript :alert(1)", "data:text/html,<script>alert(1)</script>", "DATA:text/html;base64,PHNjcmlwdD4=",
      "vbscript:msgbox(1)", "VbScript:x", "file:///etc/passwd", "blob:https://x/y", "ftp://x/y", "view-source:https://x", "foo:bar",
    ]
    safe = [
      "/", "/a/b?x=1&y=2#frag", "#frag", "?q=1", "a/b", "./a:b", "../x", "//cdn.example.com/x", "", "http://example.com", "https://example.com/a",
      "HTTPS://EXAMPLE.COM", "mailto:a@example.com", "MAILTO:a@example.com", "tel:+15551234", "/search?q=javascript:alert(1)", "/a#javascript:x",
    ]

    it "Util.safe_url keeps http, https, mailto, tel, relative paths and fragments" do
      safe.each { |url| Azu::Helpers::Util.safe_url(url).should eq(url), url.inspect }
    end

    it "Util.safe_url replaces every other scheme, whatever the case or the control characters in it" do
      unsafe.each do |url|
        Azu::Helpers::Util.safe_url(url).should eq("#"), url.inspect
        Azu::Helpers::Util.safe_url(url, "about:invalid").should eq("about:invalid"), url.inspect
      end
    end

    it "link_to never prints an unsafe href" do
      unsafe.each do |url|
        render("{{ link_to('site', u) }}", {"u" => url}).should eq(%(<a href="#">site</a>)), url.inspect
      end
      safe.each do |url|
        render("{{ link_to('site', u) }}", {"u" => url}).should eq(%(<a href="#{HTML.escape(url)}">site</a>)), url.inspect
      end
    end

    it "button_to and form_tag never print an unsafe action" do
      unsafe.each do |url|
        render("{{ button_to('Go', u) }}", {"u" => url}).should contain(%(action="about:invalid")), url.inspect
        render("{{ form_tag(u) }}", {"u" => url}).should contain(%(action="about:invalid")), url.inspect
      end
      render("{{ button_to('Go', '/posts/1', method='delete') }}").should contain %(action="/posts/1")
      render("{{ form_tag('/users') }}").should contain %(action="/users")
    end

    it "does not decode entities, so an encoded scheme stays text" do
      render("{{ link_to('x', u) }}", {"u" => "&#106;avascript:alert(1)"}).should eq %(<a href="&amp;#106;avascript:alert(1)">x</a>)
      render("{{ link_to('x', u) }}", {"u" => "javascript&colon;alert(1)"}).should eq %(<a href="javascript&amp;colon;alert(1)">x</a>)
      render("{{ link_to('x', u) }}", {"u" => "%6Aavascript:alert(1)"}).should eq %(<a href="%6Aavascript:alert(1)">x</a>)
    end

    it "keeps the quote out of the attribute" do
      render("{{ link_to('x', u) }}", {"u" => %(/a" onclick="alert(1))}).should eq %(<a href="/a&quot; onclick=&quot;alert(1)">x</a>)
    end

    it "mail_to builds its own mailto: URL" do
      render("{{ mail_to(e) }}", {"e" => "javascript:alert(1)"}).should contain %(href="mailto:javascript:alert(1)")
    end

    it "asset helpers prefix anything that is not an http(s) or absolute URL, so a scheme is never the start" do
      unsafe.reject { |url| url.starts_with?("ftp") || url.includes?('\u0000') }.each do |url|
        ["image_tag(u)", "stylesheet_tag(u)", "javascript_tag(u)", "favicon_tag(u)", "preload_tag(u, as='image')"].each do |call|
          out = render("{{ #{call} }}", {"u" => url})
          out.should_not match(/(src|href)="\s*[a-z]*script:/i), "#{call} #{url.inspect}"
          out.should_not match(/(src|href)="\s*data:/i), "#{call} #{url.inspect}"
          out.should match(/(src|href)="\/assets\//), "#{call} #{url.inspect}"
        end
      end
    end
  end

  describe "markup filters keep safe input safe and validate names" do
    it "truncate_html returns SafeString for SafeString input (the autoescaped result is not escaped again)" do
      render("{{ (x | safe) | truncate_html(100) }}", {"x" => "<p>Hello <b>World</b></p>"}).should eq "<p>Hello <b>World</b></p>"
      crinja = Crinja.new
      Azu::Helpers::Registry.apply_to(crinja)
      crinja.config.autoescape = Crinja::Config::Autoescape.new(default_for_string: true)
      crinja.from_string("{{ (x | safe) | truncate_html(100) }}").render({"x" => "<p>Hi</p>"}).should eq "<p>Hi</p>"
      crinja.from_string("{{ x | truncate_html(100) }}").render({"x" => "<p>Hi</p>"}).should eq "&lt;p&gt;Hi&lt;/p&gt;"
    end

    it "simple_format refuses a tag name and drops attribute names that are not names" do
      expect_raises(Exception) { render("{{ x | simple_format(tag=t) }}", {"x" => "a", "t" => "p onclick=alert(1)"}) }
      render("{{ x | simple_format(html_attrs=a) }}", {"x" => "a", "a" => {"class" => "c", "x onclick=alert(1) y" => "1"}}).should eq %(<p class="c">a</p>)
    end

    it "auto_link drops attribute names that are not names" do
      out = render("{{ x | auto_link(link_attrs=a) }}", {"x" => "see https://example.com", "a" => {"class" => "c", "x onclick=alert(1) y" => "1"}})
      out.should_not contain "onclick"
      out.should contain %(class="c")
    end
  end

  describe "urlize (Crinja's builds links from raw text and accepts any scheme)" do
    it "escapes the text around the links" do
      render("{{ x | urlize }}", {"x" => "<script>alert(1)</script> https://example.com/a?x=1&y=2 <b>"}).should eq(
        %(&lt;script&gt;alert(1)&lt;/script&gt; <a href="https://example.com/a?x=1&amp;y=2" rel="noopener">https://example.com/a?x=1&amp;y=2</a> &lt;b&gt;))
    end

    it "links only http, https and www. addresses" do
      render("{{ x | urlize }}", {"x" => "javascript://%0aalert(1) data://x vbscript://y"}).should_not contain "<a "
      render("{{ x | urlize }}", {"x" => "go www.example.com now"}).should contain %(<a href="http://www.example.com" rel="noopener">www.example.com</a>)
      render("{{ x | urlize }}", {"x" => "HTTPS://EXAMPLE.COM"}).should contain %(<a href="HTTPS://EXAMPLE.COM")
    end

    it "keeps a quote out of the href" do
      out = render("{{ x | urlize }}", {"x" => %(https://a.com/"onmouseover="alert(1))})
      out.should_not contain %(" onmouseover)
      out.should_not match(/href="[^"]*"[^>]*onmouseover/)
    end

    it "takes target, rel, nofollow and trim_url_limit, and text that is already safe as it is" do
      render("{{ x | urlize(target='_blank', nofollow=true) }}", {"x" => "https://a.com"}).should eq %(<a href="https://a.com" rel="nofollow noopener" target="_blank">https://a.com</a>)
      render("{{ x | urlize(trim_url_limit=10) }}", {"x" => "https://example.com/long/path"}).should contain ">https://...</a>"
      render("{{ (x | e) | urlize }}", {"x" => "a<b https://a.com"}).should eq %(a&lt;b <a href="https://a.com" rel="noopener">https://a.com</a>)
    end
  end

  describe "confirm text in a JavaScript attribute" do
    attack = "x'); alert(1); ('"

    it "Util.js_string_escape leaves plain text alone and escapes what can end a string or a script" do
      Azu::Helpers::Util.js_string_escape("Are you sure?").should eq "Are you sure?"
      Azu::Helpers::Util.js_string_escape("a'b\"c\\d\ne</script>&").should eq(
        "a\\u0027b\\u0022c\\u005cd\\u000ae\\u003c\\u002fscript\\u003e\\u0026")
    end

    it "button_to cannot be broken out of the confirm string (HTML decodes entities before JavaScript runs)" do
      out = render("{{ button_to('Del', '/x', confirm=c) }}", {"c" => attack})
      out.should contain %{onsubmit="return confirm(&#39;x\\u0027); alert(1); (\\u0027&#39;);"}
      out.should_not contain "&amp;#39;"
    end
  end
end
