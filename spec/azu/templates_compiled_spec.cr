require "../spec_helper"

private def with_template_dir(&)
  dir = File.join(Dir.tempdir, "azu_tpl_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "Azu::Templates compiled (every environment but development)" do
  it "serves a template from memory: an edit after the first load is not read" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "one {{ x }}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.compiled?.should be_true
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

  it "compiles every template at prepare, so includes and extends resolve from memory too" do
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
      error = expect_raises(Azu::Templates::CompileError) { templates.prepare }
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

  it "keeps the search order: the first directory wins" do
    with_template_dir do |dir|
      a = File.join(dir, "a")
      b = File.join(dir, "b")
      Dir.mkdir_p(a)
      Dir.mkdir_p(b)
      File.write(File.join(a, "p.jinja"), "from a")
      File.write(File.join(b, "p.jinja"), "from b")
      Azu::Templates.new([a, b], File.join(dir, "errors"), hot_reload: false).load("p.jinja").render.should eq "from a"
    end
  end

  it "still finds a template added after the compile, and reports a missing one" do
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
      compiled = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false).load("page.html").render({"x" => "<b>"})
      reloading = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true).load("page.html").render({"x" => "<b>"})
      compiled.should eq reloading
    end
  end

  it "renders concurrently from many fibers, the first of them racing to compile" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "n={{ n }}")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      results = Channel(String).new
      50.times { |i| spawn { results.send(templates.load("page.jinja").render({"n" => i})) } }
      got = Array.new(50) { results.receive }
      got.sort.should eq (0...50).map { |i| "n=#{i}" }.sort
    end
  end

  it "reloads again when reload is switched on, and compiles again when it is switched off" do
    with_template_dir do |dir|
      File.write(File.join(dir, "page.jinja"), "one")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: false)
      templates.load("page.jinja").render.should eq "one"
      templates.hot_reload = true
      templates.compiled?.should be_false
      sleep 1100.milliseconds
      File.write(File.join(dir, "page.jinja"), "two")
      File.touch(File.join(dir, "page.jinja"), Time.utc + 5.seconds)
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

describe "Azu::Templates with reload (development)" do
  it "picks up an edit made while running" do
    with_template_dir do |dir|
      file = File.join(dir, "page.jinja")
      File.write(file, "one")
      templates = Azu::Templates.new([dir], File.join(dir, "errors"), hot_reload: true)
      templates.compiled?.should be_false
      templates.prepare
      templates.load("page.jinja").render.should eq "one"
      sleep 1100.milliseconds
      File.write(file, "two")
      File.touch(file, Time.utc + 5.seconds)
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

  it "is the default for development, and every other environment compiles" do
    original = ENV["CRYSTAL_ENV"]?
    begin
      {"development" => false, "production" => true, "staging" => true}.each do |env, compiled|
        ENV["CRYSTAL_ENV"] = env
        Azu::Templates.new(["spec/test_templates"], "spec/test_errors").compiled?.should eq compiled
      end
      ENV["CRYSTAL_ENV"] = "staging"
      Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: true).compiled?.should be_false
    ensure
      original ? (ENV["CRYSTAL_ENV"] = original) : ENV.delete("CRYSTAL_ENV")
    end
  end
end
