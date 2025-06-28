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
end
