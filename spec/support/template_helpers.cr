require "file_utils"

# Runs the block with a configuration whose templates come from a fresh directory holding `files` (name => source),
# parsed once as in production. The configuration is current (`Azu.with_config`) while the block runs, so `view`
# renders from it.
def with_compiled_templates(files : Hash(String, String), & : Azu::Configuration ->) : Nil
  dir = File.tempname("azu_templates")
  Dir.mkdir_p(dir)
  files.each { |name, source| File.write(File.join(dir, name), source) }
  config = Azu::Configuration.new
  config.template_hot_reload = false
  config.templates.path = dir
  Azu.with_config(config) { yield config }
ensure
  FileUtils.rm_rf(dir) if dir
end
