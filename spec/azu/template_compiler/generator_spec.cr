require "spec"
require "../../../src/azu/template_compiler/generator"

describe Azu::TemplateCompiler do
  it "raises for a missing template directory" do
    error = expect_raises(Azu::TemplateCompiler::Error) do
      Azu::TemplateCompiler.generate("spec/fixtures/no_such_dir")
    end
    message = error.message.not_nil!
    message.should start_with "Azu::Templates.compile: no template directory spec/fixtures/no_such_dir"
    message.should contain "project root"
  end

  it "strict mode lists every template that cannot be compiled, one per line, in sorted order" do
    error = expect_raises(Azu::TemplateCompiler::Error) do
      Azu::TemplateCompiler.generate("spec/fixtures/compiled", strict: true)
    end
    lines = error.message.not_nil!.lines
    lines.first.should eq "Azu::Templates.compile: cannot compile child.jinja:1:1: extends"
    lines.should contain "comment.jinja:1:1: Note"
    lines.should contain "raw.jinja:1:1: raw"
    lines.index!("comment.jinja:1:1: Note").should be < lines.index!("raw.jinja:1:1: raw")
  end

  it "locates a note after other content at the end of the node before it" do
    Azu::TemplateCompiler.generate("spec/fixtures/compiled_notes").should contain %("late.jinja" => "late.jinja:2:3: Note")
  end

  it "locates a parse error" do
    Azu::TemplateCompiler.generate("spec/fixtures/compiled_broken").should contain %("broken.jinja" => "broken.jinja:1:1: Unclosed tag, missing: endif")
  end

  it "strict mode raises for a template that does not parse" do
    error = expect_raises(Azu::TemplateCompiler::Error) do
      Azu::TemplateCompiler.generate("spec/fixtures/compiled_broken", strict: true)
    end
    error.message.not_nil!.should contain "broken.jinja"
  end

  it "makes the build helper exit non-zero in strict mode, naming the template" do
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run("crystal", ["run", "src/azu/template_compiler/process.cr", "--", "spec/fixtures/compiled_broken", "--strict"],
      output: output, error: error)
    status.success?.should be_false
    error.to_s.should contain "broken.jinja"
  end

  it "leaves a number literal Crinja cannot parse to Crinja" do
    Dir.mkdir_p(dir = File.join(Dir.tempdir, "azu_compiled_numbers"))
    File.write(File.join(dir, "big.jinja"), "{{ 99999999999999999999 }}")
    Azu::TemplateCompiler.generate(dir).should contain %("big.jinja" => "big.jinja:Invalid Int64)
  end
end
