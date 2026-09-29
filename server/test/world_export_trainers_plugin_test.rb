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
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = true; end
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
    # the demo's own registration: two versions, from 0
    out[:counted] = t.(ev.(%Q{Phone.add(get_self,\n  :CAMPER, "Jeff", 2\n)}, %q{Phone.battle(:CAMPER, "Jeff")}))
    # a game whose phone never offers a rematch (the demo): Phone.battle never runs
    Settings.send(:remove_const, :PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING)
    Settings.const_set(:PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING, false)
    PEMK::WorldExport.instance_variable_set(:@rematches_possible, nil)
    out[:never] = t.(ev.(%q{TrainerBattle.start(:CAMPER, "Jeff")}, %q{Phone.battle(:CAMPER, "Jeff")}))
    print out.inspect
  RUBY

  # Money authority M3: a battle is fought once when every call starting it is a
  # conditional branch whose win turns on, at the branch's own level, what a later page
  # waits for. Anything else can be fought again.
  ONCE_RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters, :indent)
    Cond = Struct.new(:switch1_valid, :switch1_id, :switch2_valid, :switch2_id, :variable_valid,
                      :variable_id, :variable_value, :self_switch_valid, :self_switch_ch)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    none = Cond.new(false, 1, false, 1, false, 1, 0, false, "A")
    on_a = Cond.new(false, 1, false, 1, false, 1, 0, true, "A")
    on_b = Cond.new(false, 1, false, 1, false, 1, 0, true, "B")
    on_s = Cond.new(true, 61, false, 1, false, 1, 0, false, "A")   # a script switch: s:tsOn?("A")
    c = ->(code, params, indent = 0) { Cmd.new(code, params, indent) }
    battle = ->(args, indent = 0) { c.(111, [12, "TrainerBattle.start(#{args})"], indent) }
    after = Page.new(on_a, [c.(101, ["Well fought."]), c.(0, [])])
    ev = ->(*pages) { Ev.new(8, 3, 4, pages) }
    once = ->(e) { PEMK::WorldExport.battle_marks(e).select { |_, m| m[0] }.keys }

    out = {}
    out[:plain] = once.(ev.(Page.new(none, [battle.(%q{:BEAUTY, "Bridget"}), c.(123, ["A", 0], 1), c.(0, [], 1),
                                            c.(412, []), c.(0, [])]), after))
    out[:temp] = once.(ev.(Page.new(none, [battle.(%q{:CHAMPION, "Blue"}), c.(355, ['setTempSwitchOn("A")'], 1),
                                           c.(0, [], 1), c.(412, []), c.(0, [])]),
                           Page.new(on_s, [c.(0, [])])))
    out[:nested] = once.(ev.(Page.new(none, [battle.(%q{:TEAMROCKET_F, "Grunt", 1}),
                                             c.(111, [12, "$player.pokedex.owned_shadow_pokemon?(:ELECTABUZZ)"], 1),
                                             c.(123, ["A", 0], 2), c.(0, [], 2), c.(412, [], 1), c.(0, [], 1),
                                             c.(412, []), c.(0, [])]), after))
    out[:script] = once.(ev.(Page.new(none, [c.(355, [%q{TrainerBattle.start(:HIKER, "Ford")}]), c.(123, ["A", 0]),
                                             c.(0, [])]), after))
    out[:nothing_waits] = once.(ev.(Page.new(none, [battle.(%q{:LASS, "Crissy"}), c.(123, ["A", 0], 1), c.(0, [], 1),
                                                    c.(412, []), c.(0, [])])))
    out[:off] = once.(ev.(Page.new(none, [battle.(%q{:LASS, "Crissy"}), c.(123, ["A", 1], 1), c.(0, [], 1),
                                          c.(412, []), c.(0, [])]), after))
    # the demo's rival: one battle per starter, each in its own branch of a variable test
    out[:rival] = once.(ev.(Page.new(none, [c.(111, [1, 7, 0, 1, 0]), battle.(%q{:RIVAL1, "Blue", 1}, 1),
                                            c.(123, ["A", 0], 2), c.(0, [], 2), c.(412, [], 1), c.(0, [], 1),
                                            c.(411, []), battle.(%q{:RIVAL1, "Blue", 0}, 1), c.(123, ["A", 0], 2),
                                            c.(0, [], 2), c.(412, [], 1), c.(0, [], 1), c.(412, []), c.(0, [])]),
                            after))
    # the same battle also started by a plain script call elsewhere on the event
    out[:twice] = once.(ev.(Page.new(none, [battle.(%q{:BEAUTY, "Bridget"}), c.(123, ["A", 0], 1), c.(0, [], 1),
                                            c.(412, []), c.(0, [])]),
                            Page.new(on_a, [c.(355, [%q{TrainerBattle.start(:BEAUTY, "Bridget")}]), c.(0, [])])))
    # a second page's battle, whose rules say it pays nothing
    out[:marks] = PEMK::WorldExport.battle_marks(ev.(
      Page.new(none, [battle.(%q{:YOUNGSTER, "Ben"}), c.(123, ["A", 0], 1), c.(0, [], 1), c.(412, []), c.(0, [])]),
      Page.new(on_a, [c.(355, ["setBattleRule("]), c.(655, ['  "noMoney"']), c.(655, [")"]),
                      battle.(%q{:YOUNGSTER, "Ben", 1}), c.(123, ["B", 0], 1), c.(0, [], 1), c.(412, []), c.(0, [])]),
      Page.new(on_b, [c.(0, [])])))
    out[:partners] = PEMK::WorldExport.partners_in(
      [%Q{pbRegisterPartner(\n  :POKEMONTRAINER_May,\n  "May"\n)}, %q{pbRegisterPartner(:RIVAL1, "Blue", 2)}]
    )
    out[:computed] = PEMK::WorldExport.partners_in([%q{pbRegisterPartner(:RIVAL1, "Blue")}, "pbRegisterPartner(t, n)"])
    print out.inspect
  RUBY

  def test_a_battle_is_fought_once_when_its_win_moves_the_event_on
    out = IO.popen([RbConfig.ruby, "-W0", "-e", ONCE_RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [["BEAUTY", "Bridget", 0]], o[:plain]
    assert_equal [], o[:temp], "a temporary switch is no page condition"
    assert_equal [], o[:nested], "a mark under a further condition may never be set"
    assert_equal [], o[:script], "no branch: the battle has no win of its own"
    assert_equal [], o[:nothing_waits], "no later page waits for the mark"
    assert_equal [], o[:off], "a self-switch turned off"
    assert_equal [["RIVAL1", "Blue", 1], ["RIVAL1", "Blue", 0]], o[:rival]
    assert_equal [], o[:twice], "one call that proves nothing is enough"
    assert_equal({ ["YOUNGSTER", "Ben", 0] => [true, 0, false], ["YOUNGSTER", "Ben", 1] => [true, 1, true] }, o[:marks])
    assert_equal({ :list => [["POKEMONTRAINER_May", "May", 0], ["RIVAL1", "Blue", 2]], :computed => false }, o[:partners])
    assert_equal({ :list => [["RIVAL1", "Blue", 0]], :computed => true }, o[:computed], "a partner named at runtime")
  end

  def test_a_phone_rematch_places_every_version_it_registered
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [["CAMPER", "Jeff", 0, false]], o[:plain]
    assert_equal [["CAMPER", "Jeff", 0, true], ["CAMPER", "Jeff", 1, true], ["CAMPER", "Jeff", 2, true]], o[:rematch],
                 "no Phone.add here: every version; the first battle is a rematch's too"
    assert_equal [["PICNICKER", "Susie", 3, true]], o[:start], "from the start version on"
    assert_equal [], o[:unknown]
    assert_equal [["CAMPER", "Jeff", 0, true], ["CAMPER", "Jeff", 1, true]], o[:counted], "the versions Phone.add registered"
    assert_equal [["CAMPER", "Jeff", 0, false]], o[:never], "no rematch where the phone never offers one"
  end
end
