require "minitest/autorun"
require "rbconfig"

# A new account's starting money used to stay in the save: the ledger had no row, so the
# server counted it as $0 - a gated Mart refused the first purchase, and a first sale
# overwrote the rest. A balance the login reply has no row for now seeds the ledger with
# the save's value; one it has comes from the server, as before.
class EconomySeedPluginTest < Minitest::Test
  PLUGINS = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK
      def self.log(_m); end
      module Sync
        MARKS = []
        def self.mark_econ(field, value); MARKS << [field, value]; end
      end
    end
    %w[001_NetConfig.rb 002_MessageCodec.rb 003_NetClient.rb].each { |f| load File.join(ARGV[0], "001_Net", f) }
    load File.join(ARGV[0], "004_Persist", "001_Auth.rb")

    class Player
      attr_accessor :money, :coins, :battle_points, :soot
      def pokemmo_apply_economy(field, value); instance_variable_set("@#{field}", value); end
    end

    run = lambda do |econ, money: 3000, coins: 0|
      PEMK::Sync::MARKS.clear
      $player = Player.new
      $player.money = money; $player.coins = coins; $player.battle_points = 0; $player.soot = 0
      PEMK::Auth.instance_variable_set(:@pending_econ, econ)
      PEMK::Auth.reconcile_economy
      [PEMK::Sync::MARKS.dup, $player.money]
    end

    out = {}
    out[:new] = run.({})                                          # a new account: no rows
    out[:rows] = run.({ "money" => 500, :badges => 3 }, coins: 7)  # money on the ledger, coins not
    out[:none] = run.(nil)                                        # no economy in the reply
    print out.inspect
  RUBY

  def test_a_balance_the_ledger_lacks_is_seeded_from_the_save
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PLUGINS], err: %i[child out], &:read)
    assert $?.success?, "economy runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [[[:money, 3000]], 3000], o[:new], "the starting money reaches the ledger; nothing at 0"
    assert_equal [[[:coins, 7]], 500], o[:rows], "the ledger's money wins; the coins it lacks are seeded"
    assert_equal [[], 3000], o[:none], "no economy in the reply: nothing to go by"
  end
end
