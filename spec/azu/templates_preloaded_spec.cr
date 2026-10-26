require "../spec_helper"
require "log/spec"

private def with_template_dir(&)
  dir = File.join(Dir.tempdir, "azu_tpl_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "Azu::Templates preloaded (every environment but development)" do
  it "serves a template from memory: an edit after the first load is not read" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "one {{ x }}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.preloaded?.should be_true
      templates.load("page.jinja").render({"x" => 1}).should eq "one 1"

      File.write(File.join(dir, "page.jinja"), "two {{ x }}")
      templates.load("page.jinja").render({"x" => 1}).should eq "one 1"
    end
  end

  it "does not touch the file system per request" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "one")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(dir, "page.jinja"))
      templates.load("page.jinja").render.should eq "one"
    end
  end

  it "preloads every template at prepare, so includes and extends resolve from memory too" do
    with_template_dir do |dir|
      Dir.mkdir_p(File.join(dir, "users"))
      File.write(File.join(dir, "base.jinja"), "[{% block body %}{% endblock %}]")
      File.write(File.join(dir, "users", "_row.jinja"), "row {{ n }}")
      File.write(File.join(dir, "users", "show.jinja"), %({% extends "base.jinja" %}{% block body %}{% include "users/_row.jinja" %}{% endblock %}))
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(dir, "base.jinja"))
      File.delete(File.join(dir, "users", "_row.jinja"))
      templates.load("users/show.jinja").render({"n" => 3}).should eq "[row 3]"
    end
  end

  it "fails at prepare, naming the template and the line, when a template has a syntax error" do
    with_template_dir do |dir|
      File.write(File.join(dir, "ok.jinja"), "fine")
      File.write(File.join(dir, "broken.jinja"), "line one\n{% if %}\n")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      error = expect_raises(Azu::Templates::PreloadError) { templates.prepare }
      error.message.to_s.should contain "broken.jinja"
      error.message.to_s.should contain "broken.jinja:2:1"
    end
  end

  it "leaves a broken error.html to the built-in fallback instead of failing the boot" do
    with_template_dir do |dir|
      File.write(File.join(dir, "error.html"), "{% if %}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      templates.load("error.html").render({"status" => 500, "title" => "Boom"}).should contain "Boom"
    end
  end

  it "names templates right for a directory with a trailing slash" do
    with_template_dir do |dir|
      File.write(File.join(dir, "index.jinja"), "index")
      File.write(File.join(dir, "ndex.jinja"), "wrong")
      templates = Azu::Templates.new(["#{dir}/", "#{dir}//"], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(dir, "index.jinja"))
      templates.load("index.jinja").render.should eq "index"
      templates.load("ndex.jinja").render.should eq "wrong"
    end
  end

  it "works for a relative directory" do
    dir = "spec/tmp_rel_#{Random::Secure.hex(4)}"
    Dir.mkdir_p("#{dir}/sub")
    begin
      File.write("#{dir}/sub/a.jinja", "rel")
      templates = Azu::Templates.new(["./#{dir}"], "#{dir}/errors", hot_reload: false)
      templates.prepare
      File.delete("#{dir}/sub/a.jinja")
      templates.load("sub/a.jinja").render.should eq "rel"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "works for a directory with glob characters in its name" do
    with_template_dir do |base|
      dir = File.join(base, "t[1]{a,b}*")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "x.jinja"), "glob")
      templates = Azu::Templates.new([dir], File.join(base, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(dir, "x.jinja"))
      templates.load("x.jinja").render.should eq "glob"
    end
  end

  it "skips a directory that does not exist" do
    templates = Azu::Templates.new(["/nonexistent/azu/templates"], "/nonexistent/azu/errors", hot_reload: false)
    templates.prepare
    templates.load("error.html").render({"status" => 500, "title" => "x"}).should contain "x"
  end

  it "does not preload what preload_ignore names, and still finds it through the file loader" do
    with_template_dir do |dir|
      Dir.mkdir_p(File.join(dir, "vendor"))
      File.write(File.join(dir, "vendor", "swagger.html"), "{{ not a template }} {% if %}")
      File.write(File.join(dir, "vendor", "ok.html"), "ok")
      File.write(File.join(dir, "page.jinja"), "page")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false, preload_ignore: ["vendor/**"])
      templates.prepare
      templates.load("page.jinja").render.should eq "page"
      templates.load("vendor/ok.html").render.should eq "ok"
      expect_raises(Crinja::Error) { templates.load("vendor/swagger.html") }
    end
  end

  it "reports a template that cannot be parsed as a Crinja error, so error handlers rescue it" do
    Azu::Templates::PreloadError.new("x").should be_a Crinja::Error
  end

  it "preloads once and keeps serving the others when a template is broken and prepare was not called" do
    with_template_dir do |dir|
      File.write(File.join(dir, "good.jinja"), "good")
      File.write(File.join(dir, "bad.jinja"), "{% if %}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      3.times { templates.load("good.jinja").render.should eq "good" }
      3.times { expect_raises(Crinja::Error) { templates.load("bad.jinja") } }
      templates.preload_count.should eq 1
    end
  end

  it "falls back to the built-in error page through Response::Error rendering when the lazy preload met a broken page" do
    with_template_dir do |dir|
      File.write(File.join(dir, "error.html"), "{% if %}")
      File.write(File.join(dir, "bad.jinja"), "{% if %}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.load("error.html").render({"status" => 500, "title" => "Boom"}).should contain "Boom"
    end
  end

  it "rebuilds from the new paths when a path is added during a preload" do
    with_template_dir do |dir|
      a = File.join(dir, "a")
      b = File.join(dir, "b")
      Dir.mkdir_p(a)
      Dir.mkdir_p(b)
      File.write(File.join(a, "a.jinja"), "a")
      File.write(File.join(b, "b.jinja"), "b")
      templates = Azu::Templates.new([a], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      templates.path = b
      templates.prepare
      File.delete(File.join(b, "b.jinja"))
      templates.load("b.jinja").render.should eq "b"
    end
  end

  it "autoescapes exactly as the file loader does, per extension" do
    with_template_dir do |dir|
      {"p.html" => true, "p.jinja" => true, "p.j2" => true, "x.html.jinja" => true}.each do |name, escaped|
        File.write(File.join(dir, name), "{{ x }}")
        preloaded = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false).load(name).render({"x" => "<b>"})
        reloading = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true).load(name).render({"x" => "<b>"})
        preloaded.should eq reloading
        preloaded.should eq(escaped ? "&lt;b&gt;" : "<b>")
      end
      File.write(File.join(dir, "_inc.html"), "{{ x }}")
      File.write(File.join(dir, "outer.jinja"), %({% include "_inc.html" %}))
      preloaded = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false).load("outer.jinja").render({"x" => "<b>"})
      reloading = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true).load("outer.jinja").render({"x" => "<b>"})
      preloaded.should eq reloading
    end
  end

  it "escapes the request path in the built-in error page" do
    page = Azu::Templates.new(["/nonexistent/azu"], "/nonexistent/azu/e", hot_reload: false).load("error.html")
    page.render({"status" => 404, "title" => "Not Found", "detail" => "<script>alert(1)</script>"}).should_not contain "<script>alert(1)</script>"
  end

  it "serves a symlinked file preloaded, and leaves a symlinked directory to the file loader" do
    with_template_dir do |dir|
      real = File.join(dir, "real")
      Dir.mkdir_p(real)
      File.write(File.join(real, "inner.jinja"), "inner")
      File.write(File.join(dir, "target.jinja"), "target")
      main = File.join(dir, "main")
      Dir.mkdir_p(main)
      File.symlink(File.join(dir, "target.jinja"), File.join(main, "link.jinja"))
      File.symlink(real, File.join(main, "linked_dir"))
      templates = Azu::Templates.new([main], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(dir, "target.jinja"))
      templates.load("link.jinja").render.should eq "target"
      templates.load("linked_dir/inner.jinja").render.should eq "inner"
      File.delete(File.join(real, "inner.jinja"))
      expect_raises(Crinja::TemplateNotFoundError) { templates.load("linked_dir/inner.jinja") }
    end
  end

  it "preloads nested names and .html.jinja, and leaves a dot directory to the file loader" do
    with_template_dir do |dir|
      Dir.mkdir_p(File.join(dir, "a", "b"))
      Dir.mkdir_p(File.join(dir, ".hidden"))
      File.write(File.join(dir, "a", "b", "c.jinja"), "deep")
      File.write(File.join(dir, "page.html.jinja"), "{{ x }}")
      File.write(File.join(dir, ".hidden", "h.jinja"), "{% if %}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(dir, "a", "b", "c.jinja"))
      templates.load("a/b/c.jinja").render.should eq "deep"
      templates.load("page.html.jinja").render({"x" => "y"}).should eq "y"
      expect_raises(Crinja::Error) { templates.load(".hidden/h.jinja") }
    end
  end

  it "ignores with * inside one directory and ** across directories" do
    with_template_dir do |dir|
      Dir.mkdir_p(File.join(dir, "vendor", "sub"))
      File.write(File.join(dir, "vendor", "a.html"), "{% if %}")
      File.write(File.join(dir, "vendor", "sub", "b.html"), "{% if %}")
      one = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false, preload_ignore: ["vendor/*"])
      error = expect_raises(Crinja::Error) { one.prepare }
      error.message.to_s.should contain "vendor/sub/b.html"
      error.message.to_s.should_not contain "template vendor/a.html"
      Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false, preload_ignore: ["vendor/**"]).prepare
    end
  end

  it "keeps a name that is broken in the first directory (the lazy path: no prepare) with the file loader, not the later directory's copy" do
    with_template_dir do |dir|
      a = File.join(dir, "a")
      b = File.join(dir, "b")
      Dir.mkdir_p(a)
      Dir.mkdir_p(b)
      File.write(File.join(a, "p.jinja"), "{% if %}")
      File.write(File.join(b, "p.jinja"), "from b")
      File.write(File.join(b, "q.jinja"), "q")
      templates = Azu::Templates.new([a, b], File.join(dir, "errors"), hot_reload: false)
      templates.load("q.jinja").render.should eq "q"
      expect_raises(Crinja::Error) { templates.load("p.jinja") }
    end
  end

  it "validates on prepare although a first render preloaded leniently" do
    with_template_dir do |dir|
      File.write(File.join(dir, "good.jinja"), "good")
      File.write(File.join(dir, "bad.jinja"), "{% if %}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.load("good.jinja").render.should eq "good"
      expect_raises(Crinja::Error) { templates.prepare }
    end
  end

  it "reports an unreadable directory: strict names it, lazy skips it" do
    with_template_dir do |dir|
      locked = File.join(dir, "locked")
      Dir.mkdir_p(locked)
      File.write(File.join(dir, "ok.jinja"), "ok")
      File.chmod(locked, 0o000)
      begin
        readable = begin
          Dir.each_child(locked) { }
          true
        rescue File::Error
          false
        end
        pending!("the directory stays readable (running as root)") if readable
        error = expect_raises(Crinja::Error) { Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false).prepare }
        error.message.to_s.should contain "locked"
        lazy = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
        3.times { lazy.load("ok.jinja").render.should eq "ok" }
        lazy.preload_count.should eq 1
      ensure
        File.chmod(locked, 0o755)
      end
    end
  end

  it "keeps the search order: the first directory wins" do
    with_template_dir do |dir|
      a = File.join(dir, "a")
      b = File.join(dir, "b")
      Dir.mkdir_p(a)
      Dir.mkdir_p(b)
      File.write(File.join(a, "p.jinja"), "from a")
      File.write(File.join(b, "p.jinja"), "from b")
      templates = Azu::Templates.new([a, b], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.delete(File.join(a, "p.jinja"))
      File.delete(File.join(b, "p.jinja"))
      templates.load("p.jinja").render.should eq "from a"
    end
  end

  it "still finds a template added after the preload, and reports a missing one" do
    with_template_dir do |dir|
      File.write(File.join(dir, "first.jinja"), "1")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      File.write(File.join(dir, "late.jinja"), "late")
      templates.load("late.jinja").render.should eq "late"
      expect_raises(Crinja::TemplateNotFoundError) { templates.load("missing.jinja") }
    end
  end

  it "applies the same autoescape as the loader" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.html"), "{{ x }}")
      preloaded = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false).load("page.html").render({"x" => "<b>"})
      reloading = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true).load("page.html").render({"x" => "<b>"})
      preloaded.should eq reloading
    end
  end

  it "renders concurrently from many fibers, the first of them racing to preload" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "n={{ n }}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      results = Channel(String).new
      50.times { |i| spawn { results.send(templates.load("page.jinja").render({"n" => i})) } }
      got = Array.new(50) { results.receive }
      got.sort.should eq (0...50).map { |i| "n=#{i}" }.sort
      templates.preload_count.should eq 1
    end
  end

  it "reloads again when reload is switched on, and preloads again when it is switched off" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "one")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.load("page.jinja").render.should eq "one"
      templates.hot_reload = true
      templates.preloaded?.should be_false
      File.write(File.join(dir, "page.jinja"), "two")
      File.touch(File.join(dir, "page.jinja"), Time.utc + 5.seconds)
      templates.check_now!
      templates.load("page.jinja").render.should eq "two"
      templates.hot_reload = false
      templates.load("page.jinja").render.should eq "two"
      File.write(File.join(dir, "page.jinja"), "three")
      templates.load("page.jinja").render.should eq "two"
    end
  end

  it "rebuilds when a template path is added" do
    with_template_dir do |dir|
      other = File.join(dir, "other")
      Dir.mkdir_p(other)
      File.write(File.join(other, "extra.jinja"), "extra")
      templates = Azu::Templates.new([File.join(dir, "none")], File.join(dir, "errors"), hot_reload: false)
      templates.prepare
      templates.path = other
      templates.load("extra.jinja").render.should eq "extra"
    end
  end
end

private class DeniedTemplates < Azu::Templates
  private def each_entry(dir : String, & : String ->) : Nil
    raise File::AccessDeniedError.new("Error opening directory", file: dir) if File.basename(dir) == "locked"
    super { |entry| yield entry }
  end
end

describe "Azu::Templates with an unreadable directory (stubbed, also as root)" do
  it "raises PreloadError naming the subdirectory, with the cause attached, when strict" do
    with_template_dir do |dir|
      Dir.mkdir_p(File.join(dir, "a", "locked"))
      File.write(File.join(dir, "ok.jinja"), "ok")
      error = expect_raises(Crinja::Error) { DeniedTemplates.new([dir], File.join(dir, "errors"), hot_reload: false).prepare }
      error.message.to_s.should contain File.join(dir, "a", "locked")
      error.should be_a Azu::Templates::PreloadError
      error.cause.should be_a File::AccessDeniedError
    end
  end

  it "warns once, publishes the rest and preloads once when lazy" do
    with_template_dir do |dir|
      Dir.mkdir_p(File.join(dir, "a", "locked"))
      File.write(File.join(dir, "ok.jinja"), "ok")
      File.write(File.join(dir, "a", "inner.jinja"), "inner")
      templates = DeniedTemplates.new([dir], File.join(dir, "errors"), hot_reload: false)
      Log.capture("azu.templates") do |logs|
        3.times { templates.load("ok.jinja").render.should eq "ok" }
        logs.check(:warn, /locked was not preloaded.*may be shadowed by later directories/)
        logs.check(:debug, /preloaded \d+ templates/)
        logs.empty
      end
      templates.preload_count.should eq 1
      File.delete(File.join(dir, "ok.jinja"))
      File.delete(File.join(dir, "a", "inner.jinja"))
      templates.load("ok.jinja").render.should eq "ok"
      templates.load("a/inner.jinja").render.should eq "inner"
    end
  end
end

describe "Azu::Templates with reload (development)" do
  it "picks up an edit made while running" do
    with_template_dir do |dir|
      file = File.join(dir, "page.jinja")
      File.write(file, "one")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true)
      templates.preloaded?.should be_false
      templates.prepare
      templates.load("page.jinja").render.should eq "one"
      File.write(file, "two")
      File.touch(file, Time.utc + 5.seconds)
      templates.check_now!
      templates.load("page.jinja").render.should eq "two"
    end
  end

  it "picks up a template added while running" do
    with_template_dir do |dir|
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true)
      File.write(File.join(dir, "new.jinja"), "new")
      templates.load("new.jinja").render.should eq "new"
    end
  end

  it "is the default for development, and every other environment preloads" do
    original = ENV["CRYSTAL_ENV"]?
    begin
      {"development" => false, "production" => true, "staging" => true}.each do |env, preloaded|
        ENV["CRYSTAL_ENV"] = env
        Azu::Templates.new(["spec/test_templates"], "spec/test_errors").preloaded?.should eq preloaded
      end
      ENV["CRYSTAL_ENV"] = "staging"
      Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: true).preloaded?.should be_false
    ensure
      original ? (ENV["CRYSTAL_ENV"] = original) : ENV.delete("CRYSTAL_ENV")
    end
  end
end

describe "Azu::Configuration templates" do
  it "stops prepare on a template syntax error before it starts anything" do
    with_template_dir do |dir|
      File.write(File.join(dir, "broken.jinja"), "{% if %}")
      config = Azu::Configuration.new
      config.template_hot_reload = false
      config.templates.path = dir
      expect_raises(Crinja::Error) { config.prepare }
      config.upload.@cleanup_started.should be_false
    end
  end

  it "passes template_hot_reload= on to templates that were built already" do
    config = Azu::Configuration.new
    config.templates.@hot_reload_enabled.should eq config.template_hot_reload?
    config.template_hot_reload = !config.template_hot_reload?
    config.templates.@hot_reload_enabled.should eq config.template_hot_reload?
    config.template_hot_reload = false
    config.templates.preloaded?.should be_true
  end

  it "passes template_preload_ignore= on to templates that were built already" do
    config = Azu::Configuration.new
    config.templates
    config.template_preload_ignore = ["vendor/**"]
    config.templates.preload_ignore.should eq ["vendor/**"]
  end

  it "reads TEMPLATE_PRELOAD_IGNORE, and TEMPLATE_COMPILE_IGNORE (deprecated) when it is not set" do
    preload, compile = ENV["TEMPLATE_PRELOAD_IGNORE"]?, ENV["TEMPLATE_COMPILE_IGNORE"]?
    begin
      ENV.delete("TEMPLATE_PRELOAD_IGNORE")
      ENV["TEMPLATE_COMPILE_IGNORE"] = "old/**"
      Azu::Configuration.new.template_preload_ignore.should eq ["old/**"]
      ENV["TEMPLATE_PRELOAD_IGNORE"] = "new/**, other/*"
      Azu::Configuration.new.template_preload_ignore.should eq ["new/**", "other/*"]
      # Set, even empty, the new name wins
      ENV["TEMPLATE_PRELOAD_IGNORE"] = ""
      Azu::Configuration.new.template_preload_ignore.should be_empty
    ensure
      preload ? (ENV["TEMPLATE_PRELOAD_IGNORE"] = preload) : ENV.delete("TEMPLATE_PRELOAD_IGNORE")
      compile ? (ENV["TEMPLATE_COMPILE_IGNORE"] = compile) : ENV.delete("TEMPLATE_COMPILE_IGNORE")
    end
  end

  it "keeps the 0.5.113 names as deprecated aliases" do
    config = Azu::Configuration.new
    templates = config.templates
    config.template_compile_ignore = ["vendor/**"]
    config.template_compile_ignore.should eq ["vendor/**"]
    templates.preload_ignore.should eq ["vendor/**"]
    templates.compile_ignore = ["swagger/*"]
    templates.compile_ignore.should eq ["swagger/*"]
    config.template_hot_reload = false
    templates.compiled?.should be_true

    Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: false, compile_ignore: ["x/**"]).preload_ignore.should eq ["x/**"]
  end

  it "has one rule for the reload default, used by Configuration and Templates" do
    original = ENV["CRYSTAL_ENV"]?
    begin
      {"development" => true, "test" => true, "pipeline" => true, "staging" => false, "production" => false,
       "build" => false, "integration" => false, "acceptance" => false}.each do |env, reload|
        ENV["CRYSTAL_ENV"] = env
        Azu::Configuration.hot_reload_default.should eq reload
        Azu::Templates.new(["spec/test_templates"], "spec/test_errors").preloaded?.should eq !reload
      end
    ensure
      original ? (ENV["CRYSTAL_ENV"] = original) : ENV.delete("CRYSTAL_ENV")
    end
  end
end
