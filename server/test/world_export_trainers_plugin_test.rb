require "minitest/autorun"
require "rbconfig"

# D4 and money authority M0: the world export places each trainer battle an event starts.
# A phone rematch (Phone.battle) battles the contact's next version, which the engine
# picks at runtime: the export places every version from the start one onwards, on the
# map of the event that calls it - the demo's Jeff was placed at version 0 only.
class WorldExportTrainersPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module GameData
      Tr = Struct.new(:trainer_type, :real_name, :version)
      module Trainer
        def self.each
          [Tr.new(:CAMPER, "Jeff", 0), Tr.new(:CAMPER, "Jeff", 1), Tr.new(:CAMPER, "Jeff", 2),
           Tr.new(:PICNICKER, "Susie", 0), Tr.new(:PICNICKER, "Susie", 3)].each { |t| yield t }
        end
      end
    end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters, :indent)
    Cond = Struct.new(:switch1_valid, :switch1_id, :switch2_valid, :switch2_id, :variable_valid,
                      :variable_id, :variable_value, :self_switch_valid, :self_switch_ch)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    none = Cond.new(false, 1, false, 1, false, 1, 0, false, "A")
    ev = ->(*texts) { Ev.new(8, 3, 4, [Page.new(none, texts.map { |t| Cmd.new(355, [t], 0) } + [Cmd.new(0, [], 0)])]) }
    t = ->(e) { PEMK::WorldExport.collect_trainers(e) }

    out = {}
    out[:plain]   = t.(ev.(%q{TrainerBattle.start(:CAMPER, "Jeff")}))
    out[:rematch] = t.(ev.(%q{TrainerBattle.start(:CAMPER, "Jeff")}, %q{Phone.battle(:CAMPER, "Jeff")}))
    out[:start]   = t.(ev.(%q{Phone.battle(:PICNICKER, "Susie", 1)}))
    out[:unknown] = t.(ev.(%q{Phone.battle(:CAMPER, "Nobody")}))
    print out.inspect
  RUBY

  def test_a_phone_rematch_places_every_version
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [["CAMPER", "Jeff", 0]], o[:plain]
    assert_equal [["CAMPER", "Jeff", 0], ["CAMPER", "Jeff", 1], ["CAMPER", "Jeff", 2]], o[:rematch]
    assert_equal [["PICNICKER", "Susie", 3]], o[:start], "from the start version on"
    assert_equal [], o[:unknown]
  end
end
