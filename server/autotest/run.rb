# frozen_string_literal: true

# Entry point: bundle exec ruby autotest/run.rb [filter ...]  (see bin/autotest.sh)
# A filter keeps the scenarios whose name or file contains it.
server = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(server, "lib"), File.expand_path("../protocol", server), File.join(__dir__, "lib"))
require "pemk"
require "autotest"

Dir[File.join(__dir__, "scenarios", "*.rb")].sort.each { |f| load f }
filters  = ARGV
selected = Autotest.scenarios.select do |s|
  filters.empty? || filters.any? { |f| s.name.include?(f) || File.basename(s.file).include?(f) }
end
abort "no scenario matches #{filters.inspect}" if selected.empty?

run = Autotest::Run.new(port: Integer(ENV.fetch("AUTOTEST_PORT", "9997")))
run.kill_leftovers
run.refresh_plugins
selected.each_with_index do |s, i|
  s.index = i + 1
  puts "[#{s.index}/#{selected.length}] #{s.name}"
  s.run(run)
  puts "    #{s.status} in #{s.duration.round(1)}s#{s.error ? " - #{s.error}" : ''}"
  s.checks.each { |c| puts "      #{c.ok ? 'ok  ' : 'FAIL'} #{c.name}#{c.detail ? " (#{c.detail})" : ''}" }
end
report = Autotest::Report.new(run, selected).write
passed = selected.count { |s| s.status == :passed }
puts "#{passed}/#{selected.length} passed - #{report}"
exit(passed == selected.length ? 0 : 1)
