# frozen_string_literal: true

#==============================================================================
# Autotest: plays the real game against an isolated server and reports.
#
# Each scenario gets its own in-process PEMK server (test port, the pemk_autotest
# database, the scenario's flags) and as many game windows as it asks for. The
# windows are ordinary debug launches driven through the autopilot's file channel
# (Plugins/PEMK/011_Autopilot); they run minimized, on fresh accounts created by
# the login's config shortcut. Every wait is bounded, every scenario has a budget
# enforced by a watchdog, and a failure is written up with the state, a screenshot
# and the logs of everything involved.
#==============================================================================
require "json"
require "fileutils"
require "open3"
require "time"

module Autotest
  class Error < StandardError; end
  class Failure < Error; end
  class ChannelTimeout < Error; end
  class BudgetExceeded < Error; end

  SERVER_DIR = File.expand_path("../..", __dir__)
  GAME_DIR   = File.expand_path("..", SERVER_DIR)
  REPORTS    = File.join(GAME_DIR, "autotest-reports")

  def self.mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

require_relative "autotest/channel"
require_relative "autotest/windows"
require_relative "autotest/test_server"
require_relative "autotest/player"
require_relative "autotest/scenario"
require_relative "autotest/run"
require_relative "autotest/report"
