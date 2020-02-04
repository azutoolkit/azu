require "spec"
require "../src/azu"

ENV.fetch "CRYSTAL_ENV", "testing"

process = nil

Spec.before_suite do
  process = Process.new("./bin/test")
  sleep 15
end

Spec.after_suite do
  process.not_nil!.kill
end
