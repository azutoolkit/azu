require "crinja" # Crinja only, never azu: this helper builds quickly and runs no app code
require "./generator"
print Azu::TemplateCompiler.generate(ARGV[0]) # `Azu::Templates.compile` pastes it in as code
