require "spec"
require "../src/azu"

ENV["CRYSTAL_ENV"] ||= "testing"

process = Process.new("./bin/example_app")
# Wait for process to start
sleep 1.seconds

Spec.after_suite do
  process.not_nil!.signal Signal::KILL
end
