require "../spec_helper"
require "file_utils"

# The built-in error pages must not depend on the working directory: an app that installs azu as a shard runs from
# its own root (or from a container that holds only the compiled binary), where `./src/azu/templates` does not exist.
private def in_empty_directory(&)
  dir = File.join(Dir.tempdir, "azu_errtpl_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  original = Dir.current
  begin
    Dir.cd(dir)
    yield dir
  ensure
    Dir.cd(original)
    FileUtils.rm_rf(dir)
  end
end

describe "built-in error templates" do
  it "load from a working directory that is not the azu checkout" do
    in_empty_directory do
      templates = Azu::Configuration.new.templates

      page = templates.load("error.html").render({"status" => 404, "title" => "Not Found", "detail" => "gone"})
      page.should contain("Not Found")
      templates.load("error_debug.html").should_not be_nil
    end
  end

  it "render the production HTML error page from another working directory" do
    in_empty_directory do
      with_azu_env(Azu::Environment::Production) do
        html = Azu::Response::NotFound.new("/nope").html
        html.should contain("404")
      end
    end
  end

  it "yield to an error.html in the app's own template directory" do
    in_empty_directory do |dir|
      File.write(File.join(dir, "error.html"), "custom error page {{ status }}")
      templates = Azu::Templates.new([dir], File.join(dir, "missing"))

      templates.load("error.html").render({"status" => 500}).should eq "custom error page 500"
    end
  end

  it "stay available when ERROR_TEMPLATE points at a directory that does not exist" do
    templates = Azu::Templates.new(["spec/test_templates"], "/does/not/exist")

    templates.load("error.html").render({"status" => 500, "title" => "Boom"}).should contain("Boom")
  end
end
