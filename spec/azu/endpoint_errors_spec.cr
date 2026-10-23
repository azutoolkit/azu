require "../spec_helper"
require "file_utils"

# Compiles small programs that misuse the DSL and checks the compiler says something useful.
private def compile_error(source : String) : String
  directory = File.join(Dir.tempdir, "azu_dsl_#{Random::Secure.hex(6)}")
  Dir.mkdir_p(directory)
  file = File.join(directory, "broken.cr")
  azu = Path[Dir.current].join("src", "azu").relative_to(Path[directory]).to_s
  File.write(file, source.gsub("require \"azu\"", "require #{azu.inspect}"))

  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", file], output: output, error: output)
  status.success?.should be_false
  output.to_s.gsub(/\e\[[0-9;]*m/, "")
ensure
  FileUtils.rm_rf(directory) if directory
end

private def broken_endpoint(body : String) : String
  <<-CR
    require "azu"

    class Broken < Azu::Endpoint
      get "/broken"
    #{body.lines.map { |line| "  #{line}" }.join("\n")}
      def call
      end
    end
    CR
end

describe "Azu::Endpoint compile-time errors" do
  it "names the misspelled param option and lists the valid ones" do
    message = compile_error(broken_endpoint(<<-CR))
      params do
        param :name, String, min_lenght: 2
      end
      CR
    message.should contain "param :name: unknown option `min_lenght`"
    message.should contain "Valid options: required, default, min_length, max_length, min, max, format, in, message"
  end

  it "rejects min on a String" do
    message = compile_error(broken_endpoint(<<-CR))
      params do
        param :name, String, min: 2
      end
      CR
    message.should contain "`min`/`max` apply to numeric types"
    message.should contain "Use `min_length`/`max_length`"
  end

  it "rejects an unknown format" do
    message = compile_error(broken_endpoint(<<-CR))
      params do
        param :mail, String, format: :emial
      end
      CR
    message.should contain "unknown format `:emial`"
    message.should contain "Built-in formats: email, url"
  end

  it "rejects anything but param inside params" do
    message = compile_error(broken_endpoint(<<-CR))
      params do
        puts "hi"
      end
      CR
    message.should contain "`params do ... end` only accepts `param` declarations"
  end

  it "asks for a symbol name" do
    message = compile_error(broken_endpoint(<<-CR))
      params do
        param "name", String
      end
      CR
    message.should contain "param name must be a Symbol like `:email`"
  end

  it "explains a misspelled state assignment in assign" do
    message = compile_error(<<-CR)
      require "azu"

      class Broken
        include Azu::Component
        state count : Int32 = 0

        def reset
          assign cnt: 0
        end
      end

      Broken.new.reset
      CR
    message.should contain "undefined method 'cnt='"
  end
end
