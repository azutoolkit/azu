require "spec"
require "../src/azu"

ENV.fetch "CRYSTAL_ENV", "testing"

process = Process.new("./bin/test")
sleep 1

Spec.after_suite do
  process.not_nil!.kill
end
