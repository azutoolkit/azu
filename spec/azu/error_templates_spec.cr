require "../spec_helper"
require "file_utils"
require "log/spec"

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

  it "escapes what the built-in pages print, as the file based pages did" do
    templates = Azu::Templates.new(["x"], "/does/not/exist")
    data = {"status" => 404, "title" => "Not Found", "detail" => "<script>alert(1)</script>", "source" => "/<img src=x onerror=alert(2)>", "errors" => ["<b>e</b>"]}

    page = templates.load("error.html").render(data)
    page.should contain "&lt;script&gt;alert(1)&lt;/script&gt;"
    page.should_not contain "<script>alert(1)"
    page.should_not contain "<img src=x"
    page.should_not contain "<b>e</b>"
  end

  it "falls back to the built-in page when the app's error.html is broken" do
    in_empty_directory do |dir|
      File.write(File.join(dir, "error.html"), "{{ status | no_such_filter }} {% if %}")
      with_azu_env(Azu::Environment::Production) do
        templates = Azu::CONFIG.templates
        templates.path = dir
        begin
          Azu::Response::NotFound.new("/nope").html.should contain "Not Found"
        ensure
          templates.path.delete(dir)
        end
      end
    end
  end

  it "escapes what error_debug.html prints from the request context" do
    templates = Azu::Templates.new(["x"], "/does/not/exist")
    evil = "<script>alert(1)</script>"
    context = {
      "request_id" => evil, "method" => "GET", "endpoint" => "/<img src=x onerror=1>", "ip_address" => evil, "user_agent" => evil,
      "referer" => "https://a.example/?q=#{evil}", "user_id" => evil, "session_id" => evil, "params" => {"q" => evil},
      "headers" => {"X-Evil" => [evil]}, "environment" => {"EVIL" => evil},
    }
    page = templates.load("error_debug.html").render({
      "status" => 500, "title" => evil, "detail" => evil, "source" => evil, "errors" => [evil], "backtrace" => evil,
      "error_id" => evil, "fingerprint" => evil, "context" => context, "timestamp" => "now",
    })

    page.should contain "&lt;script&gt;alert(1)&lt;/script&gt;"
    page.should_not contain "<script>alert(1)"
    page.should_not contain "<img src=x"
  end

  it "falls back at render time (a missing partial) and says so once per template" do
    Azu::Templates.reset_logged!
    in_empty_directory do |dir|
      File.write(File.join(dir, "error.html"), %({% include "no_such_partial.html" %}))
      with_azu_env(Azu::Environment::Production) do
        templates = Azu::CONFIG.templates
        templates.path = dir
        begin
          Log.capture("azu.templates") do |logs|
            Azu::Response::NotFound.new("/a").html.should contain "Not Found"
            Azu::Response::NotFound.new("/b").html.should contain "Not Found"
            logs.check(:warn, /error.html failed to load or render/)
            logs.empty
          end
        ensure
          templates.path.delete(dir)
        end
      end
    end
  end

  it "builds the shadow notice once per process, not on every loader rebuild" do
    Azu::Templates.reset_logged!
    in_empty_directory do |dir|
      File.write(File.join(dir, "error.html"), "mine")
      Log.capture("azu.templates") do |logs|
        templates = Azu::Templates.new([dir], File.join(dir, "missing"))
        templates.path = File.join(dir, "other")
        templates.path = File.join(dir, "another")
        logs.check(:debug, /error.html replaces the built-in error.html/)
        logs.empty
      end
    end
  end
end
