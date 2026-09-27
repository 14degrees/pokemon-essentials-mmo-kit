# frozen_string_literal: true

# Subprocess body for instance_plugin_test.rb: load the real Session and Auth plugin
# files under minimal stubs, in a scratch directory, and print one JSON line of what
# PEMK_INSTANCE resolved to. The caller sets the environment for each run.

require "json"
require "tmpdir"

module SaveData
  FILE_PATH = "/saves/Game.rxdata"
end

PLUGINS = File.expand_path("../../../Plugins/PEMK", __dir__)

Dir.chdir(Dir.mktmpdir("pemk_instance"))
File.write("mmo_config.txt", "port=1111\n")
File.write("mmo_config_ap1.txt", "port=2222\n")

load File.join(PLUGINS, "001_Net/001_NetConfig.rb")
load File.join(PLUGINS, "003_Game/001_Session.rb")
load File.join(PLUGINS, "004_Persist/001_Auth.rb")

PEMK.log("probe")
puts JSON.generate(
  "instance"     => PEMK.instance,
  "config_port"  => PEMK.settings[:port],
  "save_path"    => SaveData::FILE_PATH,
  "account_file" => PEMK::Auth.account_file,
  "token_file"   => PEMK::Auth.token_file,
  "logs"         => Dir.glob("*.log").sort
)
