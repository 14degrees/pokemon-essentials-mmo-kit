require "minitest/autorun"
require "rbconfig"

# M4 Layer B snap-back on the client. A swimmer sent back stays one: dismounted on
# water it could neither step off nor surf again, and a diver could never come up.
# The engine's own pieces are stood in for as they behave: pbCancelVehicles clears the
# swimming flags unless told not to, and Scene_Map#transfer_player dismounts.
class PosCorrectPluginTest < Minitest::Test
  PLUGIN = File.expand_path("../../Plugins/PEMK/008_World/003_PosCorrect.rb", __dir__)

  RUNNER = <<~'RUBY'
    module EventHandlers; def self.add(*); end; end
    module PEMK; def self.log(_m); end; end
    Global = Struct.new(:surfing, :diving, :bicycle)
    Temp   = Struct.new(:player_new_map_id, :player_new_x, :player_new_y, :player_new_direction,
                        :player_transferring, :in_battle, :in_menu, :transition_processing)
    Map    = Struct.new(:map_id)
    class Player
      attr_reader :x, :y
      def direction; 2; end
      def moveto(x, y); @x = x; @y = y; end
    end
    class Scene_Map; end
    Tag = Struct.new(:can_surf)
    WATER = { [69, 5, 5] => true, [69, 20, 14] => true }   # (69,6,5) is the shore
    class Factory; def getTerrainTag(m, x, y) = Tag.new(WATER.fetch([m, x, y], false)); end
    module GameData
      Meta = Struct.new(:id, :dive_map_id)
      module MapMetadata
        def self.each; [Meta.new(69, 70), Meta.new(70, nil)].each { |m| yield m }; end
      end
    end
    $bikeable = { 69 => true }
    def pbCanUseBike?(m) = $bikeable[m]
    def pbCancelVehicles(destination = nil, cancel_swimming = true)
      $PokemonGlobal.surfing = false if cancel_swimming
      $PokemonGlobal.diving  = false if cancel_swimming
      $PokemonGlobal.bicycle = false if !destination || !pbCanUseBike?(destination)
    end
    def pbUpdateVehicle; end
    load ARGV[0]

    pc = PEMK::PosCorrect
    fresh = lambda do |map, surfing: false, diving: false, bicycle: false|
      $PokemonGlobal = Global.new(surfing, diving, bicycle)
      $game_temp = Temp.new(nil, nil, nil, nil, false, false, false, false)
      $game_map = Map.new(map)
      $game_player = Player.new
      $scene = Scene_Map.new
      $map_factory = Factory.new
      pc.reset
    end
    state = -> { [$game_map.map_id, $game_player.x, $game_player.y, $PokemonGlobal.surfing, $PokemonGlobal.diving] }
    # Scene_Map#transfer_player, as the engine runs it on the next frame: it dismounts.
    transfer = lambda do
      pbCancelVehicles($game_temp.player_new_map_id, true)
      $game_map = Map.new($game_temp.player_new_map_id)
      $game_player.moveto($game_temp.player_new_x, $game_temp.player_new_y)
      $game_temp.player_transferring = false
    end
    out = {}

    fresh.(69, surfing: true)                     # a surfer, sent back onto water
    pc.request(69, 5, 5); pc.tick
    out[:surf_water] = state.()
    fresh.(69, surfing: true)                     # ... or onto the shore it jumped from
    pc.request(69, 6, 5); pc.tick
    out[:surf_shore] = state.()
    fresh.(69, bicycle: true)                     # on foot (a bike where it may ride)
    pc.request(69, 6, 5); pc.tick
    out[:walker] = state.() + [$PokemonGlobal.bicycle]
    fresh.(70, diving: true)                      # a diver, sent back underwater
    pc.request(70, 12, 21); pc.tick
    out[:dive_same] = state.()
    fresh.(69, surfing: true)                     # come up where the server says it may not:
    pc.request(70, 12, 21); pc.tick               # back down, diving
    moved_early = $game_temp.player_transferring
    pc.tick                                       # not before the transfer has landed
    early = $PokemonGlobal.diving
    transfer.(); pc.tick
    out[:up_refused] = state.() + [moved_early, early]
    fresh.(70, diving: true)                      # dived where it may not: back up, surfing
    pc.request(69, 20, 14); pc.tick
    transfer.(); pc.tick
    out[:down_refused] = state.()
    print out.inspect
  RUBY

  def test_a_swimmer_sent_back_stays_one
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PLUGIN], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal [69, 5, 5, true, false], got[:surf_water]
    assert_equal [69, 6, 5, false, false], got[:surf_shore]
    assert_equal [69, 6, 5, false, false, true], got[:walker], "the bike stays where it may ride"
    assert_equal [70, 12, 21, false, true], got[:dive_same]
    assert_equal [70, 12, 21, false, true, true, false], got[:up_refused]
    assert_equal [69, 20, 14, true, false], got[:down_refused]
  end
end
