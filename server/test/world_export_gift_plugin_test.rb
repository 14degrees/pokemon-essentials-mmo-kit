require "minitest/autorun"
require "rbconfig"

# Step 6, the export half: which events are one-shot gifts. A gift is one-shot when it
# is the event's single pbReceiveItem call, on a page that turns on something a later
# page waits for (Brock: self-switch A, and his page 2 needs A). A giver with no marker,
# a later page that waits for nothing, two payouts, a cooldown, a computed item: none.
class WorldExportGiftPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters)
    Cond = Struct.new(:switch1_valid, :switch1_id, :switch2_valid, :switch2_id, :variable_valid,
                      :variable_id, :variable_value, :self_switch_valid, :self_switch_ch)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    none  = -> { Cond.new(false, 1, false, 1, false, 1, 0, false, "A") }
    self_a = -> { Cond.new(false, 1, false, 1, false, 1, 0, true, "A") }
    script = ->(s) { Cmd.new(355, [s]) }
    branch = ->(s) { Cmd.new(111, [12, s]) }
    ev = ->(*pages) { Ev.new(3, 6, 5, pages) }
    facts = lambda do |e|
      o = PEMK::WorldExport.classify_event(e)
      o && [o[:kind], o[:once], o[:dynamic], o[:quantities]]
    end

    out = {}
    out[:brock] = facts.(ev.(Page.new(none.(), [script.("pbReceiveItem(:TM80)"), Cmd.new(121, [4, 4, 0]),
                                                  Cmd.new(123, ["A", 0])]),
                             Page.new(self_a.(), [])))
    out[:no_marker] = facts.(ev.(Page.new(none.(), [branch.("pbReceiveItem(:COINCASE)")])))
    out[:page_waits_for_nothing] = facts.(ev.(Page.new(none.(), [branch.("pbReceiveItem(:BICYCLE)"),
                                                                 Cmd.new(123, ["A", 0])]),
                                              Page.new(none.(), [])))
    out[:marker_off] = facts.(ev.(Page.new(none.(), [script.("pbReceiveItem(:TM80)"), Cmd.new(123, ["A", 1])]),
                                  Page.new(self_a.(), [])))
    out[:two_payouts] = facts.(ev.(Page.new(none.(), [script.("pbReceiveItem(:POTION, 2)"),
                                                     script.("pbReceiveItem(:POTION, 5)"),
                                                     Cmd.new(123, ["A", 0])]),
                                   Page.new(self_a.(), [])))
    out[:cooldown] = facts.(ev.(Page.new(none.(), [branch.("pbReceiveItem(:BERRY)"), script.("pbSetEventTime"),
                                                  Cmd.new(123, ["A", 0])]),
                                Page.new(self_a.(), [])))
    out[:computed] = facts.(ev.(Page.new(none.(), [branch.("pbReceiveItem(:MASTERBALL)"),
                                                  branch.("pbReceiveItem(getVariable())"),
                                                  script.("pbReceiveItem(:ULTRABALL, pbGet(3))")])))
    var_cond = Cond.new(false, 1, false, 1, true, 20, 3, false, "A")
    out[:story_variable] = facts.(ev.(Page.new(none.(), [script.("pbReceiveItem(:HM01)"),
                                                        Cmd.new(122, [20, 20, 0, 0, 3])]),
                                      Page.new(var_cond, [])))
    print out.inspect
  RUBY

  def test_one_shot_gifts_are_told_apart
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal ["gift", true, false, { "TM80" => 1 }], o[:brock]
    assert_equal ["gift", false, false, { "COINCASE" => 1 }], o[:no_marker]
    assert_equal ["gift", false, false, { "BICYCLE" => 1 }], o[:page_waits_for_nothing]
    assert_equal ["gift", false, false, { "TM80" => 1 }], o[:marker_off]
    assert_equal ["gift", false, false, { "POTION" => 5 }], o[:two_payouts]
    assert_equal ["gift", false, false, { "BERRY" => 1 }], o[:cooldown]
    assert_equal ["prize", false, true, { "MASTERBALL" => 1 }], o[:computed]
    assert_equal ["gift", true, false, { "HM01" => 1 }], o[:story_variable]
  end
end
