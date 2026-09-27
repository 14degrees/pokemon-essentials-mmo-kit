# frozen_string_literal: true

module Autotest
  # One run: its id, its report directory, the test port, and the game windows it
  # started - written down, so a run that died is cleaned up by the next one.
  class Run
    PIDS = File.join(REPORTS, ".pids")

    attr_reader :run_id, :dir, :port

    def initialize(port:)
      @port   = port
      @run_id = Time.now.strftime("%Y%m%d-%H%M%S")
      @dir    = File.join(REPORTS, @run_id)
      FileUtils.mkdir_p(@dir)
    end

    def dir_for(scenario)
      d = File.join(@dir, format("%02d-%s", scenario.index, scenario.name.downcase.gsub(/[^a-z0-9]+/, "-")[0, 50]))
      FileUtils.mkdir_p(d)
      d
    end

    def track_pid(pid)
      File.open(PIDS, "a") { |f| f.puts(pid) }
    end

    # The game only recompiles its plugins when Data/PluginScripts.rxdata is gone, so a
    # plugin edited since the last compile would otherwise be tested stale. The file is
    # read at boot only; a window already open keeps what it loaded.
    def refresh_plugins
      compiled = File.join(GAME_DIR, "Data", "PluginScripts.rxdata")
      return unless File.exist?(compiled)

      newest = Dir[File.join(GAME_DIR, "Plugins", "**", "*.rb")].map { |f| File.mtime(f) }.max
      FileUtils.rm_f(compiled) if newest && newest > File.mtime(compiled)
    end

    # Windows a crashed earlier run left behind.
    def kill_leftovers
      return unless File.exist?(PIDS)

      File.readlines(PIDS, chomp: true).each do |pid|
        Windows.kill(pid) if pid.match?(/\A\d+\z/) && Windows.alive?(pid)
      end
      FileUtils.rm_f(PIDS)
    end
  end
end
