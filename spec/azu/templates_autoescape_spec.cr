require "../spec_helper"

private def with_template_dir(&)
  dir = File.join(Dir.tempdir, "azu_esc_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private ATTACK  = "<script>alert(1)</script>"
private ESCAPED = "&lt;script&gt;alert(1)&lt;/script&gt;"

# {preloaded at prepare, preloaded lazily on the first render, reloading from the file system}
private def each_mode(dir : String, & : String, Azu::Templates ->)
  yield "prepared", Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false).tap(&.prepare)
  yield "lazy", Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
  yield "reloading", Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true)
end

describe "Azu::Templates autoescape" do
  it "escapes user text in a .jinja and a .j2 page without | e, in every loading mode" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "<p>{{ x }}</p>")
      File.write(File.join(dir, "page.j2"), "<p>{{ x }}</p>")
      each_mode(dir) do |mode, templates|
        {"page.jinja", "page.j2"}.each do |name|
          templates.load(name).render({"x" => ATTACK}).should eq("<p>#{ESCAPED}</p>"), "#{mode} #{name}"
        end
      end
    end
  end

  it "escapes values that come out of attributes, loops and filters" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), %(<a title="{{ x }}">{% for i in items %}{{ i }}{% endfor %}{{ x | upper }}</a>))
      each_mode(dir) do |mode, templates|
        out = templates.load("page.jinja").render({"x" => %("><b>), "items" => ["<i>", "&"]})
        out.should eq(%(<a title="&quot;&gt;&lt;b&gt;">&lt;i&gt;&amp;&quot;&gt;&lt;B&gt;</a>)), mode
      end
    end
  end

  it "keeps | safe as the opt-out" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "{{ x | safe }}|{{ x }}")
      each_mode(dir) do |mode, templates|
        templates.load("page.jinja").render({"x" => "<b>"}).should eq("<b>|&lt;b&gt;"), mode
      end
    end
  end

  it "leaves | e harmless: a value is escaped once, not twice" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "{{ x | e }}|{{ x | escape }}|{{ x | e | e }}")
      each_mode(dir) do |mode, templates|
        templates.load("page.jinja").render({"x" => "<b>&"}).should eq("&lt;b&gt;&amp;|&lt;b&gt;&amp;|&lt;b&gt;&amp;"), mode
      end
    end
  end

  it "does not touch numbers, booleans and nil" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "{{ n }} {{ f }} {{ b }} {{ 1 + 2 }}")
      each_mode(dir) do |mode, templates|
        templates.load("page.jinja").render({"n" => 42, "f" => 1.5, "b" => true}).should eq("42 1.5 true 3"), mode
      end
    end
  end

  it "escapes in included, extended and imported templates" do
    with_template_dir do |dir|
      File.write(File.join(dir, "_part.jinja"), "[{{ x }}]")
      File.write(File.join(dir, "_part.html"), "(({{ x }}))")
      File.write(File.join(dir, "_macros.jinja"), "{% macro show(v) %}<{{ v }}>{% endmacro %}")
      File.write(File.join(dir, "base.jinja"), "<main>{% block body %}{% endblock %}</main>")
      File.write(File.join(dir, "child.jinja"), %({% extends "base.jinja" %}{% block body %}{{ x }}{% endblock %}))
      File.write(File.join(dir, "outer.jinja"), %({% include "_part.jinja" %}{% include "_part.html" %}{% from "_macros.jinja" import show %}{{ show(x) }}))
      each_mode(dir) do |mode, templates|
        templates.load("outer.jinja").render({"x" => ATTACK}).should eq("[#{ESCAPED}]((#{ESCAPED}))<#{ESCAPED}>"), mode
        templates.load("child.jinja").render({"x" => ATTACK}).should eq("<main>#{ESCAPED}</main>"), mode
      end
    end
  end

  it "does not escape plain text templates (x.txt.jinja, x.txt)" do
    with_template_dir do |dir|
      File.write(File.join(dir, "mail.txt.jinja"), "Hi {{ x }}")
      File.write(File.join(dir, "mail.txt"), "Hi {{ x }}")
      each_mode(dir) do |mode, templates|
        templates.load("mail.txt.jinja").render({"x" => "A&B"}).should eq("Hi A&B"), mode
        templates.load("mail.txt").render({"x" => "A&B"}).should eq("Hi A&B"), mode
      end
    end
  end

  it "does not escape formats that are not HTML (x.json.jinja, x.md.jinja, ...), and escapes xml, rss, atom and svg" do
    with_template_dir do |dir|
      %w(json js mjs css csv md markdown yml yaml sql sh txt text).each do |ext|
        File.write(File.join(dir, "f.#{ext}.jinja"), "{{ x }}")
      end
      %w(xml rss atom svg html htm).each { |ext| File.write(File.join(dir, "m.#{ext}.jinja"), "{{ x }}") }
      each_mode(dir) do |mode, templates|
        %w(json js mjs css csv md markdown yml yaml sql sh txt text).each do |ext|
          templates.load("f.#{ext}.jinja").render({"x" => "a&b"}).should eq("a&b"), "#{mode} #{ext}"
        end
        %w(xml rss atom svg html htm).each do |ext|
          templates.load("m.#{ext}.jinja").render({"x" => "a&b"}).should eq("a&amp;b"), "#{mode} #{ext}"
        end
      end
    end
  end

  it "honours {% autoescape false %} and {% autoescape true %} blocks" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "{{ x }}|{% autoescape false %}{{ x }}{% endautoescape %}|{{ x }}")
      File.write(File.join(dir, "mail.txt.jinja"), "{{ x }}|{% autoescape true %}{{ x }}{% endautoescape %}")
      each_mode(dir) do |mode, templates|
        templates.load("page.jinja").render({"x" => "<b>"}).should eq("&lt;b&gt;|<b>|&lt;b&gt;"), mode
        templates.load("mail.txt.jinja").render({"x" => "<b>"}).should eq("<b>|&lt;b&gt;"), mode
      end
    end
  end

  it "escapes a template added after the compile (found by the file loader)" do
    with_template_dir do |dir|
      File.write(File.join(dir, "first.jinja"), "1")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.write(File.join(dir, "late.jinja"), "{{ x }}")
      templates.load("late.jinja").render({"x" => ATTACK}).should eq ESCAPED
    end
  end

  it "escapes a template string rendered through the environment" do
    with_template_dir do |dir|
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.crinja.from_string("{{ x }}").render({"x" => ATTACK}).should eq ESCAPED
    end
  end

  it "escapes the same way through Configuration#templates, the object Renderable#view loads from" do
    with_template_dir do |dir|
      File.write(File.join(dir, "view.jinja"), "<h1>{{ title }}</h1>")
      config = Azu::Configuration.new
      config.templates.path = dir
      config.template_hot_reload = false
      config.templates.load("view.jinja").render({"title" => ATTACK}).should eq "<h1>#{ESCAPED}</h1>"
    end
  end

  it "renders the benchmark template (which still says | e) to the same bytes with and without autoescape" do
    dir = File.expand_path("../../benchmark/apps/common", __DIR__)
    items = [{"id" => 1, "name" => "A & <B>", "price" => 9.5}, {"id" => 2, "name" => "plain", "price" => 3}]
    on = Azu::Templates.new([dir], "/nonexistent", hot_reload: false).load("template.jinja").render({"items" => items})
    off = Azu::Templates.new([dir], "/nonexistent", hot_reload: false, autoescape: false).load("template.jinja").render({"items" => items})
    on.should eq off
    on.should contain %(<li class="item-1">A &amp; &lt;B&gt; (9.5)</li>)
  end

  describe "the built-in helpers (they return Crinja::SafeString and must not be escaped again)" do
    it "renders their markup as markup" do
      Azu::Helpers::Builtin.register_all
      with_template_dir do |dir|
        File.write(File.join(dir, "helpers.jinja"), <<-'JINJA')
          {{ form_tag("/users", method="post") }}{{ csrf_field() }}{{ label_tag("u_name", "Name") }}{{ text_field("u", "name", value=x) }}{{ textarea("u", "bio", value=x) }}{{ hidden_field("u", "h", value=x) }}{{ checkbox("u", "ok", label=x) }}{{ radio_button("u", "r", value="a", label=x) }}{{ select_field("u", "s", options=[x, "b"]) }}{{ submit_button("Go") }}{{ end_form() }}
          {{ link_to("Home", "/", class="nav") }}{{ link_to(x, "/x") }}{{ button_to("Delete", "/posts/1", method="delete") }}{{ mail_to("a@example.com", "Mail") }}
          {{ stylesheet_tag("app.css") }}{{ javascript_tag("app.js") }}{{ image_tag("logo.png", alt=x) }}{{ favicon_tag("favicon.ico") }}{{ preload_tag("f.woff2", as="font") }}
          {{ content_tag(name="p", content=x, class="c") }}{{ x | highlight("script") }}{{ x | simple_format }}{{ x | safe_html }}{{ csrf_meta() }}{{ time_tag(time=0) }}
          JINJA
        each_mode(dir) do |mode, templates|
          out = templates.load("helpers.jinja").render({"x" => ATTACK})
          out.should_not contain("&lt;form"), mode
          out.should_not contain("&lt;a "), mode
          out.should_not contain("&lt;input"), mode
          out.should_not contain("&lt;link"), mode
          out.should_not contain("&lt;img"), mode
          out.should_not contain("&lt;button"), mode
          out.should_not contain("&amp;lt;"), mode
          out.should_not contain("&amp;quot;"), mode
          out.should_not contain("&amp;amp;"), mode
          out.should contain("<form "), mode
          out.should contain(%(<a href="/" class="nav">Home</a>)), mode
          out.should contain("</form>"), mode
          out.should contain(%(<input type="hidden" name="_csrf")), mode
          out.should contain(%(<link rel="stylesheet" href="/assets/app.css" />)), mode
          out.should contain("<p>#{ESCAPED}</p>"), mode
          out.should contain("<p class=\"c\">#{ESCAPED}</p>"), mode
          out.should contain("&lt;<mark>script</mark>&gt;alert(1)&lt;/<mark>script</mark>&gt;"), mode
          out.scan("<script>").size.should eq(1), "#{mode}: only the javascript_tag and the safe_html filter may emit <script>"
        end
      end
    end

    it "does not double-escape the text a helper escaped itself" do
      Azu::Helpers::Builtin.register_all
      with_template_dir do |dir|
        File.write(File.join(dir, "h.jinja"), %({{ link_to(x, "/") }}))
        each_mode(dir) do |mode, templates|
          templates.load("h.jinja").render({"x" => "Tom & <Jerry>"}).should eq(%(<a href="/">Tom &amp; &lt;Jerry&gt;</a>)), mode
        end
      end
    end
  end

  describe "the switch" do
    it "turns .jinja escaping off per Templates instance" do
      with_template_dir do |dir|
        File.write(File.join(dir, "page.jinja"), "{{ x }}")
        File.write(File.join(dir, "page.html"), "{{ x }}")
        templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false, autoescape: false)
        templates.load("page.jinja").render({"x" => "<b>"}).should eq "<b>"
        templates.load("page.html").render({"x" => "<b>"}).should eq "&lt;b&gt;"
        templates.crinja.from_string("{{ x }}").render({"x" => "<b>"}).should eq "<b>"
      end
    end

    it "is on by default and read from the configuration" do
      Azu::Configuration.new.template_autoescape?.should be_true
      with_template_dir do |dir|
        File.write(File.join(dir, "page.jinja"), "{{ x }}")
        config = Azu::Configuration.new
        config.templates.path = dir
        config.template_hot_reload = false
        config.templates.load("page.jinja").render({"x" => "<b>"}).should eq "&lt;b&gt;"
        config.template_autoescape = false
        config.template_autoescape?.should be_false
        config.templates.load("page.jinja").render({"x" => "<b>"}).should eq "<b>"
        config.template_autoescape = true
        config.templates.load("page.jinja").render({"x" => "<b>"}).should eq "&lt;b&gt;"
      end
    end

    it "warns at boot when autoescape is off, or the variable has a value that is not recognised" do
      old = ENV["TEMPLATE_AUTOESCAPE"]?
      begin
        warnings = ->(value : String?) do
          value ? (ENV["TEMPLATE_AUTOESCAPE"] = value) : ENV.delete("TEMPLATE_AUTOESCAPE")
          backend = ::Log::MemoryBackend.new
          config = Azu::Configuration.new
          config.log = ::Log.new("spec.autoescape", backend, :warn)
          config.warn_about_template_autoescape
          backend.entries.map(&.message)
        end
        warnings.call(nil).should be_empty
        warnings.call("true").should be_empty
        warnings.call("false").first.should contain "template_autoescape is off"
        {"0", "no", "off", "FALSE"}.each do |value|
          message = warnings.call(value).first
          message.should contain value.inspect
          message.should contain "autoescape stays on"
        end
        backend = ::Log::MemoryBackend.new
        config = Azu::Configuration.new
        config.log = ::Log.new("spec.autoescape", backend, :warn)
        config.template_autoescape = false
        config.warn_about_template_autoescape
        backend.entries.size.should eq 1
      ensure
        old ? (ENV["TEMPLATE_AUTOESCAPE"] = old) : ENV.delete("TEMPLATE_AUTOESCAPE")
      end
    end

    it "does not call TEMPLATE_AUTOESCAPE unrecognised when code set template_autoescape" do
      old = ENV["TEMPLATE_AUTOESCAPE"]?
      begin
        ENV["TEMPLATE_AUTOESCAPE"] = "false"
        backend = ::Log::MemoryBackend.new
        config = Azu::Configuration.new
        config.log = ::Log.new("spec.autoescape", backend, :warn)
        config.template_autoescape = true
        config.warn_about_template_autoescape
        backend.entries.should be_empty
        config.template_autoescape = false
        config.warn_about_template_autoescape
        backend.entries.map(&.message).first.should contain "template_autoescape is off"
      ensure
        old ? (ENV["TEMPLATE_AUTOESCAPE"] = old) : ENV.delete("TEMPLATE_AUTOESCAPE")
      end
    end

    it "reads TEMPLATE_AUTOESCAPE=false, and keeps escaping for any other value" do
      old = ENV["TEMPLATE_AUTOESCAPE"]?
      begin
        ENV["TEMPLATE_AUTOESCAPE"] = "false"
        Azu::Configuration.new.template_autoescape?.should be_false
        {"true", "", "0", "no", "off"}.each do |value|
          ENV["TEMPLATE_AUTOESCAPE"] = value
          Azu::Configuration.new.template_autoescape?.should be_true
        end
      ensure
        old ? (ENV["TEMPLATE_AUTOESCAPE"] = old) : ENV.delete("TEMPLATE_AUTOESCAPE")
      end
    end
  end
end
