# Crinja only, never azu: this helper builds quickly and runs no app code
require "./generator"

begin
  print Azu::TemplateCompiler.generate(ARGV[0], strict: ARGV[1]? == "--strict") # `Azu::Templates.compile` pastes it in as code
rescue e : Azu::TemplateCompiler::Error
  STDERR.puts e.message # `run` turns it into a compile error at the `compile` call
  exit 1
end
