require "minitest/autorun"
require "rbconfig"

# A Pokemon another player built (a trade's escrow, a PvP team) is checked before this
# game holds it: bytes naming a class outside the allow list are refused before
# anything is built, a Pokemon whose instance variables do not have the shape the game
# relies on is refused, and the texts another player wrote lose their message codes.
class PeerPokemonPluginTest < Minitest::Test
  NET = File.expand_path("../../Plugins/PEMK/001_Net", __dir__)

  RUNNER = <<~'RUBY'
    $log = []
    $built = false
    module PEMK
      NAME_MAX = 12
      def self.log(m); $log << m; end
      module Config; PEER_CLASSES = %w[Pokemon Pokemon::Move Pokemon::Owner Mail].freeze; end
    end
    module GameData
      class Base; def self.exists?(s); self::IDS.include?(s); end; end
      class Species < Base; IDS = %i[PIKACHU RESHIRAM].freeze; end
      class Status  < Base; IDS = %i[NONE POISON].freeze; end
      class Ability < Base; IDS = %i[STATIC].freeze; end
      class Nature  < Base; IDS = %i[HARDY].freeze; end
      class Item    < Base; IDS = %i[POKEBALL ORANBERRY GRASSMAIL].freeze; end
      class Move    < Base; IDS = %i[THUNDERSHOCK].freeze; end
    end
    class Pokemon
      MAX_MOVES = 4
      class Move; end
      class Owner; end
    end
    class Mail; end
    class Stranger
      def marshal_dump; 1; end
      def marshal_load(_x); $built = true; end
    end
    load File.join(ARGV[0], "004_MarshalScan.rb")
    load File.join(ARGV[0], "005_PeerPokemon.rb")
    P = PEMK::PeerPokemon

    def obj(klass, ivars)
      o = klass.allocate
      ivars.each { |k, v| o.instance_variable_set(k, v) }
      o
    end

    def mon(extra = {})
      move  = obj(Pokemon::Move, :@id => :THUNDERSHOCK, :@pp => 30, :@ppup => 0)
      owner = obj(Pokemon::Owner, :@id => 12_345, :@name => "Red\\c[2]", :@gender => 0, :@language => 2)
      obj(Pokemon, { :@species => :PIKACHU, :@form => 0, :@exp => 1000, :@hp => 30, :@totalhp => 30,
                     :@attack => 20, :@defense => 15, :@spatk => 18, :@spdef => 16, :@speed => 30,
                     :@status => :NONE, :@statusCount => 0, :@gender => 1, :@ability => nil,
                     :@ability_index => nil, :@nature => :HARDY, :@item => nil, :@poke_ball => :POKEBALL,
                     :@moves => [move], :@first_moves => [], :@ribbons => [], :@iv => { HP: 31 },
                     :@ev => { HP: 0 }, :@happiness => 70, :@name => "Pika\\v[1]<b>", :@owner => owner,
                     :@personalID => 77, :@timeReceived => 1_700_000_000 }.merge(extra))
    end

    out = {}
    P.adopt_mode("on")
    got = P.load(Marshal.dump(mon), "escrow")
    out[:valid] = [got.class.name, got.instance_variable_get(:@name),
                   got.instance_variable_get(:@owner).instance_variable_get(:@name)]
    out[:moves] = P.refusal(mon(:@moves => "Tackle"))
    out[:species] = P.refusal(mon(:@species => :MISSINGNO))
    out[:ivs] = P.refusal(mon(:@iv => { HP: "31" }))
    out[:stray] = P.refusal(mon(:@shiny => 1))
    out[:mail] = P.refusal(mon(:@mail => obj(Mail, :@item => :GRASSMAIL, :@message => "hi", :@sender => "Red")))
    out[:fusion] = P.refusal(mon(:@species => :RESHIRAM, :@fused => mon(:@hp => -1)))
    out[:not_a_pokemon] = P.refusal("Pikachu")
    party = [mon, mon(:@moves => nil)]
    out[:party] = [P.load(Marshal.dump(party), "team"), $log.last]

    foreign = Marshal.dump([mon, Stranger.new])
    out[:foreign_on] = [P.load(foreign, "team"), $built, $log.last]
    P.adopt_mode("shadow")
    out[:foreign_shadow] = [P.load(foreign, "team").class.name, $built]
    $built = false
    P.adopt_mode("off")
    got = P.load(Marshal.dump(mon(:@moves => nil)), "escrow")
    out[:off] = [got.class.name, got.instance_variable_get(:@name)]
    print out.inspect
  RUBY

  def test_peer_pokemon
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, NET], err: %i[child out], &:read)
    assert $?.success?, "peer pokemon runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal ["Pokemon", "Pikav[1]b", "Redc[2]"], o[:valid]
    assert_equal "moves", o[:moves]
    assert_equal "species", o[:species]
    assert_equal "IVs", o[:ivs]
    assert_equal "shiny", o[:stray]
    assert_nil o[:mail]
    assert_equal "fusion", o[:fusion]
    assert_equal "not a Pokemon", o[:not_a_pokemon]
    assert_nil o[:party][0]
    assert_includes o[:party][1], "Pokemon 2: moves"
    assert_nil o[:foreign_on][0]
    assert_equal false, o[:foreign_on][1], "the refused bytes built nothing"
    assert_includes o[:foreign_on][2], "class Stranger"
    assert_equal ["Array", true], o[:foreign_shadow]
    assert_equal ["Pokemon", "Pikav[1]b"], o[:off]
  end
end
