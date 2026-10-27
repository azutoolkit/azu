require "../../spec_helper"
require "file_utils"

private def with_project(&)
  root = File.join(Dir.tempdir, "azu_frames_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(File.join(root, "src"))
  yield root
ensure
  root.try { |dir| FileUtils.rm_rf(dir) }
end

describe Azu::ExceptionPage::Frame do
  it "reads the file, line, column and method of a backtrace line" do
    frame = Azu::ExceptionPage::Frame.parse("src/app.cr:12:5 in 'call'", "/srv/app")

    frame.file.should eq "src/app.cr"
    frame.path.should eq "/srv/app/src/app.cr"
    frame.line.should eq 12
    frame.column.should eq 5
    frame.method.should eq "call"
    frame.location.should eq "src/app.cr:12"
  end

  it "tells the app, its shards, Azu and Crystal apart" do
    kind = ->(line : String) { Azu::ExceptionPage::Frame.parse(line, "/srv/app").kind }

    kind.call("/srv/app/src/endpoints/show.cr:3:1 in 'call'").should eq Azu::ExceptionPage::Frame::Kind::App
    kind.call("lib/crinja/src/crinja.cr:3:1 in 'render'").should eq Azu::ExceptionPage::Frame::Kind::Shard
    kind.call("lib/azu/src/azu/router.cr:3:1 in 'process'").should eq Azu::ExceptionPage::Frame::Kind::Azu
    kind.call("/usr/share/crystal/src/hash.cr:1202:9 in '[]'").should eq Azu::ExceptionPage::Frame::Kind::Crystal
    kind.call("??? at 0x0").should eq Azu::ExceptionPage::Frame::Kind::Crystal

    Azu::ExceptionPage::Frame.parse("lib/crinja/src/crinja.cr:3:1 in 'render'", "/srv/app").shard.should eq "crinja"
  end

  it "keeps a line without a location as it is" do
    frame = Azu::ExceptionPage::Frame.parse("from libc.so.6 in '__libc_start_main'", "/srv/app")

    frame.line.should be_nil
    frame.location.should eq "from libc.so.6 in '__libc_start_main'"
  end

  it "counts a Crystal installed inside the project as Crystal, not the app" do
    with_project do |root|
      stdlib = File.join(root, "vendor", "crystal", "src")
      Dir.mkdir_p(stdlib)
      File.write(File.join(stdlib, "prelude.cr"), "")
      File.write(File.join(stdlib, "kernel.cr"), "")

      Azu::ExceptionPage::Frame.parse("#{stdlib}/hash.cr:1:1 in '[]'", root).kind.should eq Azu::ExceptionPage::Frame::Kind::Crystal
    end
  end

  describe "#excerpt" do
    it "reads the lines around an app frame" do
      with_project do |root|
        File.write(File.join(root, "src", "app.cr"), (1..20).map { |n| "line #{n}" }.join('\n'))
        excerpt = Azu::ExceptionPage::Frame.parse("src/app.cr:10:1 in 'x'", root).excerpt(root).not_nil!

        excerpt.start.should eq 4
        excerpt.line.should eq 10
        excerpt.lines.first.should eq "line 4"
        excerpt.lines.last.should eq "line 16"
      end
    end

    it "never reads a file outside the project" do
      with_project do |root|
        Azu::ExceptionPage::Frame.parse("/etc/passwd:1:1 in 'x'", root).excerpt(root).should be_nil
        Azu::ExceptionPage::Frame.parse("src/../../outside.cr:1:1 in 'x'", root).excerpt(root).should be_nil
      end
    end
  end

  describe "#editor_url" do
    frame = Azu::ExceptionPage::Frame.parse("src/my app.cr:7:3 in 'call'", "/srv/app")

    it "is nil without AZU_EDITOR" do
      frame.editor_url(nil).should be_nil
    end

    it "links a named editor" do
      frame.editor_url("vscode").should eq "vscode://file//srv/app/src/my%20app.cr:7:3"
      frame.editor_url("idea").should eq "idea://open?file=/srv/app/src/my%20app.cr&line=7"
    end

    it "fills a template of the developer's own" do
      frame.editor_url("myeditor://%{file}#L%{line}").should eq "myeditor:///srv/app/src/my%20app.cr#L7"
    end

    it "ignores an unknown name" do
      frame.editor_url("notepad").should be_nil
    end
  end
end
