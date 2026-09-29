require "minitest/autorun"
require "rbconfig"

# Money authority M0: the battle data export says what each trainer type pays per level
# (base money), what each trainer's Pokemon hold and know - the moves the engine gives
# them when the PBS names none (Pokemon#reset_moves: the last four learned by their
# level) - and the money a new game starts with.
class BattleDataMoneyPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/009_BattleData/001_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    class Pokemon; MAX_MOVES = 4; end
    module GameData
      TT = Struct.new(:id, :base_money)
      module TrainerType
        def self.each; [TT.new(:CAMPER, 16), TT.new(:LEADER_Brock, 100)].each { |t| yield t }; end
      end
      Meta = Struct.new(:start_money)
      module Metadata; def self.get; Meta.new(3000); end; end
      Sp = Struct.new(:moves)
      module Species
        def self.get_species_form(species, _form)
          case species
          when :MEOWTH then Sp.new([[1, :SCRATCH], [1, :GROWL], [6, :BITE], [9, :FAKEOUT], [12, :PAYDAY], [17, :SCRATCH]])
          else Sp.new([[1, :TACKLE]])
          end
        end
      end
      Tr = Struct.new(:trainer_type, :real_name, :version, :pokemon)
      module Trainer
        def self.each
          [Tr.new(:CAMPER, "Liam", 0, [{ species: :MEOWTH, level: 20, item: :AMULETCOIN },
                                      { species: :DIGLETT, level: 8, moves: [:DIG, nil] }])].each { |t| yield t }
        end
      end
    end
    module GameData
      module Move; def self.each; end; end
      module Item; def self.each; end; end
      module Species; def self.each; end; end
    end
    load ARGV[0]
    X = PEMK::BattleDataExport
    %i[caps_map natures_map growth_rates_map type_matrix abilities_list item_rules stamp].each do |m|
      X.define_singleton_method(m) { {} }
    end
    doc = X.build_document
    print({ types: doc[:trainer_types], rules: doc[:money_rules], trainers: doc[:trainers] }.inspect)
  RUBY

  def test_trainer_money_moves_and_start_money
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal({ "CAMPER" => { "base_money" => 16 }, "LEADER_Brock" => { "base_money" => 100 } }, o[:types])
    assert_equal({ "start_money" => 3000 }, o[:rules])
    liam = o[:trainers].first
    assert_equal ["CAMPER", "Liam", 0], liam.values_at("type", "name", "version")
    assert_equal ["MEOWTH", 20, "AMULETCOIN", %w[BITE FAKEOUT PAYDAY SCRATCH]], liam["party"][0],
                 "the last four learned by level 20; Scratch relearned last"
    assert_equal ["DIGLETT", 8, nil, %w[DIG]], liam["party"][1], "the moves its PBS entry names"
  end
end
