require "minitest/autorun"
require "rbconfig"

# The checkpoint saves on its own after the game changes. A high-value change (a
# trade, a catch, a badge) must reach the server at once: a crash before a
# throttled push brings the older blob back at login, which after a trade takes
# both Pokémon away. Ambient saves keep the 30s wire throttle.
class CheckpointPluginTest < Minitest::Test
  CHECKPOINT = File.expand_path("../../Plugins/PEMK/004_Persist/007_Checkpoint.rb", __dir__)

  RUNNER = <<~'RUBY'
    require "tmpdir"
    $pushes = []
    $clock  = 100.0
    module PEMK
      def self.log(_m); end
      module Auth; def self.logged_in?; true; end; end
      module Sync
        def self.mark_flags; end
        def self.flush_event(_e); end
        def self.mark_blob_watermark; end
        def self.push_blob(_file, force:); $pushes << force; :pushed; end
      end
      module BattleSetup; def self.launch_pending?; false; end; end
      module Trade; def self.busy?; false; end; end
    end
    module SaveData; FILE_PATH = File.join(Dir.mktmpdir, "Game.rxdata"); end
    module Game
      def self.pokemmo_orig_save(path, safe: false); File.binwrite(path, "SAVE"); true; end
    end
    module EventHandlers; def self.add(*); end; end
    class Scene_Map; end
    class FakePlayer; def moving?; false; end; end
    Temp = Struct.new(:in_battle, :in_menu, :in_storage, :message_window_showing,
                      :player_transferring, :transition_processing, :in_mini_update)
    $scene       = Scene_Map.new
    $game_temp   = Temp.new(false, false, false, false, false, false, false)
    $game_player = FakePlayer.new
    $game_system = Struct.new(:save_disabled).new(false)
    $player      = Object.new
    def pbMapInterpreterRunning?; false; end
    def pbAddPokemon(*); true; end
    def pbAddPokemonSilent(*); true; end
    def pbAddToParty(*); true; end
    def pbTrainerPC; end
    def pbPokeCenterPC; end
    load ARGV[0]

    ck = PEMK::Checkpoint
    ck.define_singleton_method(:mono) { $clock }
    ck.tick                                  # the session's baseline
    ck.request(:map)
    $clock += 25.0
    ck.tick                                  # an ambient checkpoint
    ck.request(:trade)
    $clock += 1.5
    ck.tick                                  # a trade's
    ck.request(:battle)
    $clock += 0.5
    ck.tick                                  # within the urgent floor: not yet
    $clock += 0.6
    ck.tick
    print $pushes.inspect
    $stdout.flush
    exit!(0)                                 # skip the plugin's at_exit backstop
  RUBY

  def test_urgent_checkpoints_push_at_once_and_ambient_ones_are_throttled
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, CHECKPOINT], err: %i[child out], &:read)
    assert $?.success?, "checkpoint runner crashed:\n#{out}"
    assert_equal "[false, true, true]", out.strip
  end
end
