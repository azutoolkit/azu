require "spec"
require "../src/azu"

ENV.fetch "CRYSTAL_ENV", "testing"

process = Process.new("./bin/test", shell: true)
sleep 1
