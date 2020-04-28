require "spec"
require "../src/azu"

ENV.fetch "CRYSTAL_ENV", "testing"

process = Process.new("./bin/test")
# Wait for process to start
sleep 2.seconds

Spec.after_suite do
  process.not_nil!.kill
end
