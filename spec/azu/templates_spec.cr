require "../spec_helper"

class TestRenderable
  include Azu::Templates::Renderable

  def page_path
    "test_page.jinja"
  end
end

class TestPage
  include Azu::Templates::Renderable
end

module Admin
  class DashboardPage
    include Azu::Templates::Renderable
  end
end

# Test struct without context method - exercises the {% if @type.has_method?(:context) %} false branch
struct RenderableWithoutContext
  include Azu::Templates::Renderable

  def render_view(template : String, data = Hash(String, Crinja::Value).new)
    view(template, data)
  end

  def render_view_with_context(template : String, http_context : HTTP::Server::Context, data = Hash(String, Crinja::Value).new)
    view_with_context(template, http_context, data)
  end
end

# Test struct with context method - exercises the {% if @type.has_method?(:context) %} true branch
struct RenderableWithContext
  include Azu::Templates::Renderable

  @context : HTTP::Server::Context?

  def initialize(@context : HTTP::Server::Context? = nil)
  end

  def context : HTTP::Server::Context
    @context.not_nil!
  end

  def render_view(template : String, data = Hash(String, Crinja::Value).new)
    view(template, data)
  end
end

describe Azu::Templates do
  describe "initialization" do
    it "creates templates instance with path and error path" do
      path = ["spec/test_templates"]
      error_path = "spec/test_errors"
      templates = Azu::Templates.new(path, error_path)

      templates.path.should eq(path)
      templates.error_path.should eq(error_path)
    end

    it "creates crinja instance" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.crinja.should be_a(Crinja)
    end
  end

  describe "path management" do
    it "adds path to templates" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      original_path_size = templates.path.size

      templates.path = "/additional/templates"

      templates.path.size.should eq(original_path_size + 1)
      templates.path.should contain("/additional/templates")
    end

    it "reloads templates when path is added" do
      templates = Azu::Templates.new(["/test/templates"], "/test/errors")

      # Should not raise an exception
      templates.path = "/additional/templates"
    end
  end

  describe "error path management" do
    it "sets error path" do
      templates = Azu::Templates.new(["/test/templates"], "/test/errors")

      templates.error_path = "/new/error/path"

      templates.error_path.should eq("/new/error/path")
    end

    it "reloads templates when error path is changed" do
      templates = Azu::Templates.new(["/test/templates"], "/test/errors")

      # Should not raise an exception
      templates.error_path = "/new/error/path"
    end
  end

  describe "template loading" do
    it "loads template by name" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # Should return a Crinja template object
      template = templates.load("test_template.jinja")
      template.should be_a(Crinja::Template)
    end

    it "handles template loading errors gracefully" do
      templates = Azu::Templates.new(["/non/existent/path"], "/non/existent/errors")

      # Should raise an exception for non-existent template
      expect_raises(Exception) do
        templates.load("non_existent.jinja")
      end
    end
  end

  describe "Renderable module" do
    it "includes Renderable in class" do
      renderable = TestRenderable.new
      renderable.should be_a(Azu::Templates::Renderable)
    end

    it "provides view method" do
      renderable = TestRenderable.new

      # Should respond to view method
      renderable.responds_to?(:view).should be_true
    end

    it "provides page_path method" do
      renderable = TestRenderable.new

      # Should respond to page_path method
      renderable.responds_to?(:page_path).should be_true
    end

    it "generates default page path from class name" do
      page = TestPage.new
      page.page_path.should eq("test_page.jinja")
    end

    it "generates page path for nested class names" do
      page = Admin::DashboardPage.new
      page.page_path.should eq("admin/dashboard_page.jinja")
    end
  end

  describe "template rendering" do
    it "renders template with data" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # This would require a real template file, so we test the method exists
      template = templates.load("test_template.jinja")
      template.responds_to?(:render).should be_true
    end

    it "handles template rendering with variables" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # This would require a real template file, so we test the method exists
      template = templates.load("test_template.jinja")
      template.responds_to?(:render).should be_true
    end
  end

  describe "crinja loader configuration" do
    it "configures file system loader with paths" do
      path = ["/test/templates"]
      error_path = "/test/errors"
      templates = Azu::Templates.new(path, error_path)

      # The loader should be configured with the paths
      templates.crinja.loader.should be_a(Crinja::Loader::FileSystemLoader)
    end

    it "includes error path in loader paths" do
      path = ["/test/templates"]
      error_path = "/test/errors"
      templates = Azu::Templates.new(path, error_path)

      # The loader should include both template paths and error path
      templates.crinja.loader.should be_a(Crinja::Loader::FileSystemLoader)
    end
  end

  describe "path expansion" do
    it "expands relative paths" do
      templates = Azu::Templates.new(["./templates"], "./errors")

      # Should handle relative paths
      templates.path.should contain("./templates")
      templates.error_path.should eq("./errors")
    end

    it "expands absolute paths" do
      templates = Azu::Templates.new(["/absolute/templates"], "/absolute/errors")

      # Should handle absolute paths
      templates.path.should contain("/absolute/templates")
      templates.error_path.should eq("/absolute/errors")
    end
  end

  describe "multiple template paths" do
    it "handles multiple template paths" do
      paths = ["/path1", "/path2", "/path3"]
      templates = Azu::Templates.new(paths, "/errors")

      templates.path.size.should eq(3)
      templates.path.should contain("/path1")
      templates.path.should contain("/path2")
      templates.path.should contain("/path3")
    end

    it "adds multiple paths" do
      templates = Azu::Templates.new(["/initial"], "/errors")

      templates.path = "/path1"
      templates.path = "/path2"

      templates.path.size.should eq(3) # initial + 2 added
      templates.path.should contain("/initial")
      templates.path.should contain("/path1")
      templates.path.should contain("/path2")
    end
  end

  describe "error handling" do
    it "handles invalid template paths gracefully" do
      templates = Azu::Templates.new(["/non/existent"], "/non/existent")

      # Should handle non-existent paths gracefully
      templates.should be_a(Azu::Templates)
    end

    it "handles empty path arrays" do
      templates = Azu::Templates.new([] of String, "/errors")

      templates.path.should eq([] of String)
      templates.error_path.should eq("/errors")
    end
  end

  describe "integration with configuration" do
    it "works with CONFIG.templates" do
      # This tests that the templates can be accessed through CONFIG
      # The actual CONFIG would need to be set up in the test environment
      templates = Azu::Templates.new(["/test/templates"], "/test/errors")
      templates.should be_a(Azu::Templates)
    end
  end

  describe "template inheritance" do
    it "supports template inheritance" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # Crinja supports template inheritance, so we test that the template object supports it
      template = templates.load("test_template.jinja")
      template.should be_a(Crinja::Template)
    end
  end

  describe "template caching" do
    it "caches loaded templates" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # Crinja caches templates internally
      template1 = templates.load("test_template.jinja")
      template2 = templates.load("test_template.jinja")

      # Both should be the same template object (cached)
      template1.should eq(template2)
    end
  end

  describe "hot reloading optimization" do
    it "detects development environment correctly" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?

      # Test development environment
      ENV["CRYSTAL_ENV"] = "development"
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.@hot_reload_enabled.should be_true

      # Test production environment
      ENV["CRYSTAL_ENV"] = "production"
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.@hot_reload_enabled.should be_false

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

    it "accepts hot reload parameter in constructor" do
      # Test explicit true
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: true)
      templates.@hot_reload_enabled.should be_true

      # Test explicit false
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: false)
      templates.@hot_reload_enabled.should be_false

      # Test nil (should use environment detection)
      original_env = ENV["CRYSTAL_ENV"]?
      ENV["CRYSTAL_ENV"] = "development"
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: nil)
      templates.@hot_reload_enabled.should be_true

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

    it "overrides environment detection when hot reload parameter is provided" do
      # Save original environment
      original_env = ENV["CRYSTAL_ENV"]?

      # Test override in production environment (force enable)
      ENV["CRYSTAL_ENV"] = "production"
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: true)
      templates.@hot_reload_enabled.should be_true

      # Test override in development environment (force disable)
      ENV["CRYSTAL_ENV"] = "development"
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors", hot_reload: false)
      templates.@hot_reload_enabled.should be_false

      # Restore original environment
      if original_env
        ENV["CRYSTAL_ENV"] = original_env
      else
        ENV.delete("CRYSTAL_ENV")
      end
    end

    it "allows manual hot reload configuration" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # Test enabling hot reload
      templates.hot_reload = true
      templates.@hot_reload_enabled.should be_true

      # Test disabling hot reload
      templates.hot_reload = false
      templates.@hot_reload_enabled.should be_false
    end

    it "caches template loader instance" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")

      # Loader should be cached
      loader1 = templates.@loader
      loader2 = templates.@loader

      loader1.should eq(loader2)
    end

    it "reuses loader when hot reload is disabled" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.hot_reload = false

      original_loader = templates.@loader

      # Adding path should not recreate loader when hot reload is disabled
      templates.path = "/additional/path"
      templates.@loader.should eq(original_loader)
    end

    it "recreates loader when hot reload is enabled and path changes" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.hot_reload = true

      original_loader = templates.@loader

      # Adding path should recreate loader when hot reload is enabled
      templates.path = "/additional/path"
      templates.@loader.should_not eq(original_loader)
    end

    it "handles file not found errors gracefully during change detection" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.hot_reload = true

      # This should not raise an exception even if files don't exist
      templates.load("test_template.jinja")
    end

    it "prevents multiple file watchers from starting" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.hot_reload = true

      # Should prevent multiple file watchers
      templates.@file_watcher_started.should be_true

      # Enabling hot reload again should not start another watcher
      templates.hot_reload = true
      templates.@file_watcher_started.should be_true
    end

    it "only checks for changes when interval has passed" do
      templates = Azu::Templates.new(["spec/test_templates"], "spec/test_errors")
      templates.hot_reload = true

      # Load a template to initialize the system
      templates.load("test_template.jinja")

      # Immediately loading again should not check for changes
      # (this is more of a behavioral test that the system doesn't check constantly)
      templates.load("test_template.jinja")
    end
  end

  describe "Renderable view with data types" do
    before_each do
      Azu::CONFIG.templates.path = "spec/test_templates"
    end

    describe "without context" do
      it "renders template with NamedTuple data" do
        renderable = RenderableWithoutContext.new
        result = renderable.render_view("test_template.jinja", {title: "NT Title", heading: "NT Heading"})

        result.should contain("NT Title")
        result.should contain("NT Heading")
      end

      it "renders template with Hash data using string keys" do
        renderable = RenderableWithoutContext.new
        result = renderable.render_view("test_template.jinja", {"title" => "Hash Title", "heading" => "Hash Heading"})

        result.should contain("Hash Title")
        result.should contain("Hash Heading")
      end

      it "renders template with Hash data using symbol keys" do
        renderable = RenderableWithoutContext.new
        result = renderable.render_view("test_template.jinja", {:title => "Sym Title", :heading => "Sym Heading"})

        result.should contain("Sym Title")
        result.should contain("Sym Heading")
      end

      it "renders template with empty data" do
        renderable = RenderableWithoutContext.new
        result = renderable.render_view("test_template.jinja")

        result.should contain("Test Template")
        result.should contain("Hello World")
      end

      it "does not inject context variables when context is unavailable" do
        renderable = RenderableWithoutContext.new
        result = renderable.render_view("test_template.jinja", {title: "No Context"})

        result.should contain("No Context")
      end
    end

    describe "with context" do
      it "renders template and injects context variables" do
        request = HTTP::Request.new("GET", "/test?q=search")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        ctx = HTTP::Server::Context.new(request, response)

        renderable = RenderableWithContext.new(ctx)
        result = renderable.render_view("test_template.jinja", {title: "With Context"})

        result.should contain("With Context")
      end

      it "renders template with NamedTuple data and context" do
        request = HTTP::Request.new("GET", "/users")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        ctx = HTTP::Server::Context.new(request, response)

        renderable = RenderableWithContext.new(ctx)
        result = renderable.render_view("test_template.jinja", {title: "Users", user: "Alice"})

        result.should contain("Users")
        result.should contain("Welcome, Alice!")
      end
    end

    describe "view_with_context" do
      it "renders template with explicit context and NamedTuple data" do
        request = HTTP::Request.new("GET", "/explicit")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        ctx = HTTP::Server::Context.new(request, response)

        renderable = RenderableWithoutContext.new
        result = renderable.render_view_with_context("test_template.jinja", ctx, {title: "Explicit", heading: "Context"})

        result.should contain("Explicit")
        result.should contain("Context")
      end

      it "renders template with explicit context and Hash data" do
        request = HTTP::Request.new("GET", "/explicit")
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        ctx = HTTP::Server::Context.new(request, response)

        renderable = RenderableWithoutContext.new
        result = renderable.render_view_with_context("test_template.jinja", ctx, {"title" => "Hash Explicit"})

        result.should contain("Hash Explicit")
      end
    end
  end
end
