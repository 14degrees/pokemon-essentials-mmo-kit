require "minitest/autorun"
require "rbconfig"

# Step 5, client half: the server repairs owned values the client changed some
# other way than the game's own writes. The repair lands at a safe frame, leaves
# alone any id the game wrote again since the snapshot it was judged on, never
# overwrites an object the game parked in a variable, and is not echoed back as a
# write. The login cooldown restore, which the server cannot see, is recorded.
class FlagRepairPluginTest < Minitest::Test
  PERSIST = File.expand_path("../../Plugins/PEMK/004_Persist", __dir__)

  RUNNER = <<~'RUBY'
    $flags_seq = 0
    def _INTL(s, *_a); s; end
    def pbMapInterpreterRunning?; false; end
    module EventHandlers; def self.add(*); end; end
    class Scene_Map; end
    class Game_Switches
      def initialize; @data = []; end
      def [](i); @data[i] || false; end
      def []=(i, v); @data[i] = v; end
    end
    class Game_Variables
      def initialize; @data = []; end
      def [](i); @data[i] || 0; end
      def []=(i, v); @data[i] = v; end
    end
    class Game_SelfSwitches
      def initialize; @data = {}; end
      def [](k); @data[k] == true; end
      def []=(k, v); @data[k] = v; end
    end
    class Interpreter
      def command_121; end
      def command_122; end
      def command_123; end
    end
    Temp = Struct.new(:in_battle, :message_window_showing, :player_transferring)
    FakeMap = Struct.new(:need_refresh, :map_id)
    Global = Struct.new(:eventvars)
    module PEMK
      def self.log(_m); end
      def self.enabled?; true; end
      module Sync
        def self.flags_seq; $flags_seq; end
        def self.mark_flags; end
      end
    end
    load File.join(ARGV[0], "010_FlagDelta.rb")
    load File.join(ARGV[0], "009_Flags.rb")

    $scene = Scene_Map.new
    $game_temp = Temp.new(false, false, false)
    $game_map = FakeMap.new(false, 5)
    $game_switches = Game_Switches.new
    $game_variables = Game_Variables.new
    $game_self_switches = Game_SelfSwitches.new
    $PokemonGlobal = Global.new({})

    f = PEMK::Flags
    f.adopt_mode("on")
    f.adopt_policy({ "switches" => { "4" => "fact", "31" => "mirror" }, "variables" => { "7" => "mirror", "8" => "mirror" } })

    $flags_seq = 5
    $game_variables[7] = 10                  # the game writes var 7 after snapshot 5 was sent
    $game_variables[8] = :a_pokemon          # the game parks an object in var 8
    f::Delta.drain

    f.note_repair({ :seq => 5, :switches => { 4 => true, 31 => false }, :variables => { "7" => 3, "8" => 2 },
                    :self_switches => { "2:3:A" => true } })
    f.tick_repair
    echoed = f::Delta.drain

    out = [$game_switches[4], $game_switches[31], $game_variables[7], $game_variables[8],
           $game_self_switches[[2, 3, "A"]], echoed.nil?, $game_map.need_refresh]

    # the cooldown restore at login: its self-switch A travels as a recorded write
    f.restore_cooldowns({ "13:17" => 1_000 })
    cooled = f::Delta.drain
    out << (cooled && cooled[:self_switches])
    print out.inspect
  RUBY

  def test_a_repair_lands_fenced_and_is_not_echoed
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PERSIST], err: %i[child out], &:read)
    assert $?.success?, "flag repair runner crashed:\n#{out}"
    assert_equal '[true, false, 10, :a_pokemon, true, true, true, {"13:17:A"=>true}]', out.strip
  end
end
