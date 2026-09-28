require "minitest/autorun"
require "rbconfig"

# The sync layer coalesces state changes and flushes them to the server. During a
# battle nothing leaves on its own: the party projection a catch or a win changes
# must follow the battle's end report, or the server judges the EXP it carries
# against a reward window not yet open (a SUSPECT level jump).
class SyncPluginTest < Minitest::Test
  SYNC = File.expand_path("../../Plugins/PEMK/006_Sync/001_Sync.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []
    module Graphics; @f = 0; def self.frame_count; @f; end; def self.step(n); @f += n; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m[:type]; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Monsters
        def self.pending_batch(_max = 64); [[], false]; end
        def self.projection; [{ uid: 1, species: :SQUIRTLE, level: 8 }]; end
      end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module TeamReport; def self.build; nil; end; end
      module Checkpoint; def self.request(_r); end; end
    end
    Temp = Struct.new(:in_battle)
    $game_temp = Temp.new(true)
    load ARGV[0]

    PEMK::Sync.mark_mon
    Graphics.step(400)                 # past the debounce and the staleness cap
    PEMK::Sync.tick
    during = $sent.dup
    $game_temp.in_battle = false
    PEMK::Sync.tick
    print [during, $sent].inspect
  RUBY

  def test_nothing_leaves_mid_battle_and_all_of_it_right_after
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, SYNC], err: %i[child out], &:read)
    assert $?.success?, "sync runner crashed:\n#{out}"
    assert_equal "[[], [:mon_party]]", out.strip
  end
end

# Step 6: the server settles a gift grant with the first bag snapshot after the
# client's :gift_applied, so no bag snapshot may leave while a gift waits for its
# grant or its report, and the owed gifts go out before the bag on a new connection.
class SyncGiftHoldPluginTest < Minitest::Test
  SYNC = SyncPluginTest::SYNC

  RUNNER = <<~'RUBY'
    $sent = []
    module Graphics; @f = 0; def self.frame_count; @f; end; def self.step(n); @f += n; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m[:type]; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Inventory; def self.full_bag; { "TM80" => 1 }; end; end
      module Monsters; def self.pending_batch(_max = 64); [[], false]; end; def self.projection; nil; end; end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module TeamReport; def self.build; nil; end; end
      module GiftClaim
        @holding = true
        def self.holding?; @holding; end
        def self.release; @holding = false; end
        def self.before_bag_flush; $sent << :gift_req; end
      end
    end
    $game_temp = Struct.new(:in_battle).new(false)
    load ARGV[0]

    PEMK::Sync.mark_inv
    Graphics.step(400)
    PEMK::Sync.tick
    PEMK::Sync.flush_event(:menu)   # a direct flush holds the bag back too
    during = $sent.dup
    PEMK::GiftClaim.release
    PEMK::Sync.tick
    print [during, $sent].inspect
  RUBY

  def test_the_bag_waits_for_the_gift_and_follows_the_owed_requests
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, SYNC], err: %i[child out], &:read)
    assert $?.success?, "sync runner crashed:\n#{out}"
    assert_equal "[[], [:gift_req, :inv]]", out.strip
  end
end
