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

  it "strict mode raises for the first unsupported template in sorted order" do
    error = expect_raises(Azu::TemplateCompiler::Error) do
      Azu::TemplateCompiler.generate("spec/fixtures/compiled", strict: true)
    end
    message = error.message.not_nil!
    message.should contain "comment.jinja"
    message.should contain ":1:"
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
end
