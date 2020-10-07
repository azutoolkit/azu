require "spec"
require "../src/azu"

ENV["CRYSTAL_ENV"] ||= "test"

process = Process.new("./bin/example_app")
# Wait for process to start
sleep 2.seconds

Spec.after_suite do
  sleep 1.seconds
  process.not_nil!.signal Signal::KILL
end
