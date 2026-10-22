require "../../spec_helper"

# These specs prove that mistakes are rejected by the compiler, so each case is a program that
# is compiled (without generating code) in a child process. Crystal only checks code that is
# reachable, hence every program also drives its component the way an application would.

private COMPONENT = <<-CR
  class Page < Azu::Spark::Component
    mountable

    prop label : String = "x"
    prop size : Int32
    state count : Int32 = 0

    event def inc(by : Int32 = 1) : Nil
      self.count += by
    end
  %s
  end

  Azu::Spark::Testing.mount(Page, size: 1) { |view| view.trigger("inc").html }
CR

private def page(body : String, usage : String = "") : String
  COMPONENT % body + "\n#{usage}\n"
end

private CASES = {
  "well formed" => page(<<-CR, %(Azu::Spark.render(Page, size: 3, label: "ok"))),
    def render
      button "go", **spark_click(:inc, by: 2)
    end
  CR

  "undeclared event" => page(<<-CR),
    def render
      button "go", **spark_click(:dec)
    end
  CR

  "state of the wrong type" => page(<<-CR),
    event def reset : Nil
      self.count = "zero"
    end

    def render
    end
  CR

  "bulk assign of unknown state" => page(<<-CR),
    event def reset : Nil
      assign missing: 1
    end

    def render
    end
  CR

  "prop of the wrong type" => page("def render\nend", %(Azu::Spark.render(Page, size: "big"))),
  "missing prop"           => page("def render\nend", %(Azu::Spark.render(Page))),
  "unknown prop"           => page("def render\nend", %(Azu::Spark.render(Page, size: 1, color: "red"))),

  "component that is not mountable" => <<-CR,
    class Child < Azu::Spark::Component
      def render
      end
    end

    Azu::Spark.render(Child)
  CR

  "event parameter that cannot be decoded" => page(<<-CR),
    event def bad(options : Hash(String, String)) : Nil
    end

    def render
    end
  CR

  "untyped event parameter" => page("event def bad(x) : Nil\nend\ndef render\nend"),

  "state without default" => <<-CR,
    class Page < Azu::Spark::Component
      state count : Int32

      def render
      end
    end
  CR

  "reserved name" => <<-CR,
    class Page < Azu::Spark::Component
      prop socket : String

      def render
      end
    end
  CR

  "child with mismatching props" => <<-CR,
    class Row < Azu::Spark::Component
      prop number : Int32

      def render
      end
    end

    class Table < Azu::Spark::Component
      def render
        live Row, key: "1", number: "one"
      end
    end

    Azu::Spark::Testing.mount(Table) { |view| view.html }
  CR
}

# Compiles *source* and returns the compiler's complaint, or nil when it compiled.
private def compile_error(source : String) : String?
  path = File.join(Dir.tempdir, "azu_spark_compile_#{Random::Secure.hex(6)}.cr")
  library = Path[File.expand_path("../../../src/azu", __DIR__)].relative_to(Dir.tempdir)
  File.write(path, %(require "#{library}"\n#{source}))
  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", path], output: output, error: output)
  status.success? ? nil : output.to_s
ensure
  File.delete(path) if path && File.exists?(path)
end

describe "Spark compile time safety" do
  results = {} of String => String?

  before_all do
    next unless Process.find_executable("crystal")

    queue = ::Channel({String, String}).new
    done = ::Channel(Nil).new
    3.times do
      spawn do
        while job = queue.receive?
          results[job[0]] = compile_error(job[1])
        end
        done.send(nil)
      end
    end
    CASES.each { |name, source| queue.send({name, source}) }
    queue.close
    3.times { done.receive }
  end

  rejected = ->(name : String) do
    pending!("needs the crystal compiler on PATH") unless results.has_key?(name)
    results[name].not_nil!
  end

  it "accepts a well formed component" do
    pending!("needs the crystal compiler on PATH") unless results.has_key?("well formed")
    results["well formed"].should be_nil
  end

  it "rejects a binding to an event the component does not declare" do
    rejected.call("undeclared event").should contain "does not declare `event def dec`"
  end

  it "rejects assigning the wrong type to state" do
    rejected.call("state of the wrong type").should contain "expected argument #1 to 'Page#count=' to be Int32"
  end

  it "rejects bulk assignment of unknown state" do
    rejected.call("bulk assign of unknown state").should contain "declares no state named missing"
  end

  it "rejects props of the wrong type, missing props and unknown props" do
    declaration = %(Page.new(*, label : String = "x", size : Int32))
    ["prop of the wrong type", "missing prop", "unknown prop"].each do |name|
      rejected.call(name).should contain declaration
    end
  end

  it "rejects rendering a component that is not mountable" do
    rejected.call("component that is not mountable").should contain "must declare `mountable`"
  end

  it "rejects event parameters that cannot be decoded from a payload" do
    rejected.call("event parameter that cannot be decoded").should contain "are not supported"
  end

  it "rejects untyped event parameters, state without default and reserved names" do
    rejected.call("untyped event parameter").should contain "needs a type restriction"
    rejected.call("state without default").should contain "needs a default value"
    rejected.call("reserved name").should contain "is used by Azu::Spark::Component"
  end

  it "rejects a child whose props do not match its declaration" do
    rejected.call("child with mismatching props").should contain "Row#__spark_assign_props(*, number : Int32 = @number)"
  end
end
