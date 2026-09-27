require "minitest/autorun"
require "json"
require "rbconfig"

# The autopilot drives a game window for automated tests. Its plugin files load in a
# subprocess under minimal engine stubs and are stepped frame by frame the way the
# engine steps them: the command channel, the virtual keys the engine reads, and the
# state snapshot the agent reasons over.
class AutopilotPluginTest < Minitest::Test
  RUNNER = File.join(File.expand_path("..", __dir__), "test", "support", "autopilot_plugin_runner.rb")

  def test_the_autopilot_plugins_behave
    out = IO.popen([RbConfig.ruby, "-W0", RUNNER], err: %i[child out], &:read)
    assert $?.success?, "autopilot runner crashed:\n#{out}"

    results = JSON.parse(out.lines.last)
    refute_empty results
    failures = results.reject { |_, v| v == "ok" }
    assert_empty failures, "autopilot behaviour failed:\n" \
                           "#{failures.map { |k, v| "  #{k}: #{v}" }.join("\n")}\n\n#{out}"
  end

  BATTLE_RUNNER = File.join(File.expand_path("..", __dir__), "test", "support", "autopilot_battle_runner.rb")

  # Battle decisions over a fake Battle::Scene: keys / agent / auto modes, refusals
  # reported back, a ball thrown at the only foe, the stuck-turn breaker, and the
  # wait_until / choose verbs.
  def test_battle_decisions_behave
    out = IO.popen([RbConfig.ruby, "-W0", BATTLE_RUNNER], err: %i[child out], &:read)
    assert $?.success?, "battle runner crashed:\n#{out}"

    results = JSON.parse(out.lines.last)
    refute_empty results
    failures = results.reject { |_, v| v == "ok" }
    assert_empty failures, "battle behaviour failed:\n" \
                           "#{failures.map { |k, v| "  #{k}: #{v}" }.join("\n")}\n\n#{out}"
  end

  WORLD_RUNNER = File.join(File.expand_path("..", __dir__), "test", "support", "autopilot_world_runner.rb")

  # Walking on a fake map (a detour around a wall, no path, an interrupting message),
  # talking to an NPC, the events list, and text entry through "type".
  def test_world_verbs_behave
    out = IO.popen([RbConfig.ruby, "-W0", WORLD_RUNNER], err: %i[child out], &:read)
    assert $?.success?, "world runner crashed:\n#{out}"

    results = JSON.parse(out.lines.last)
    refute_empty results
    failures = results.reject { |_, v| v == "ok" }
    assert_empty failures, "world behaviour failed:\n" \
                           "#{failures.map { |k, v| "  #{k}: #{v}" }.join("\n")}\n\n#{out}"
  end

  # Off unless a debug launch AND the env var: a player build must never be remote-controlled.
  def test_it_stays_off_without_a_debug_launch
    code = <<~RUBY
      module PEMK; def self.log(_m); end; end
      $DEBUG = false
      ENV["PEMK_AUTOPILOT"] = Dir.tmpdir
      require "tmpdir"
      load #{File.expand_path("../../Plugins/PEMK/011_Autopilot/001_Autopilot.rb", __dir__).inspect}
      print PEMK::Autopilot.active?
    RUBY
    out = IO.popen([RbConfig.ruby, "-W0", "-rtmpdir", "-e", code], err: %i[child out], &:read)
    assert_equal "false", out.strip
  end
end
