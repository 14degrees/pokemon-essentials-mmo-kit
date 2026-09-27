require "minitest/autorun"
require "json"
require "rbconfig"

# PEMK_INSTANCE runs a window as a separate player on the same PC. Each instance must
# get its own config, account, session token, log and save file, and an unset or
# malformed name must leave the pre-existing file names untouched. The plugin files
# load in a subprocess so the environment of each run stays isolated.
class InstancePluginTest < Minitest::Test
  RUNNER = File.join(File.expand_path("..", __dir__), "test", "support", "instance_plugin_runner.rb")

  def run_with(env)
    out = IO.popen([env, RbConfig.ruby, "-W0", RUNNER], err: %i[child out], &:read)
    assert $?.success?, "instance runner crashed:\n#{out}"
    JSON.parse(out.lines.last)
  end

  def test_a_named_instance_gets_its_own_files
    r = run_with("PEMK_INSTANCE" => "ap1", "PEMK_GUEST" => nil)
    assert_equal "ap1", r["instance"]
    assert_equal 2222, r["config_port"], "reads mmo_config_ap1.txt"
    assert_equal "/saves/Game_ap1.rxdata", r["save_path"]
    assert_equal "mmo_account_ap1.dat", r["account_file"]
    assert_equal "mmo_session_ap1.dat", r["token_file"]
    assert_equal ["mmo_ap1.log"], r["logs"]
  end

  def test_no_instance_keeps_the_default_files
    r = run_with("PEMK_INSTANCE" => nil, "PEMK_GUEST" => nil)
    assert_nil r["instance"]
    assert_equal 1111, r["config_port"]
    assert_equal "/saves/Game.rxdata", r["save_path"]
    assert_equal "mmo_account.dat", r["account_file"]
    assert_equal "mmo_session.dat", r["token_file"]
    assert_equal ["mmo.log"], r["logs"]
  end

  # The name ends up in file paths: anything but a plain token is ignored.
  def test_a_malformed_name_is_ignored
    r = run_with("PEMK_INSTANCE" => "../evil", "PEMK_GUEST" => nil)
    assert_nil r["instance"]
    assert_equal "/saves/Game.rxdata", r["save_path"]
    assert_equal ["mmo.log"], r["logs"]
  end

  # The older guest mode is unchanged when no instance is named.
  def test_the_guest_mode_is_untouched
    r = run_with("PEMK_INSTANCE" => nil, "PEMK_GUEST" => "1")
    assert_equal "mmo_account_guest.dat", r["account_file"]
    assert_equal "mmo_session_guest.dat", r["token_file"]
    assert_equal "/saves/Game.rxdata", r["save_path"]
  end
end
