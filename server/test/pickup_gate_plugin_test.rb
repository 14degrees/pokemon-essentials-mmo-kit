require "minitest/autorun"
require "rbconfig"

# M4 Layer C, client half: once the server said it grants pickups, an item ball is
# added only on a grant. A dropped link leaves the ball where it is - a local pickup
# then would let cutting the connection skip the gate and its one-shot.
class PickupGatePluginTest < Minitest::Test
  WORLD = File.expand_path("../../Plugins/PEMK/008_World", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $taken = 0; $up = true; $grant = true
    def pbMessage(_m); end
    def pbUpdateSceneMap; end
    module Input; def self.update; end; end
    module Graphics
      def self.update
        PEMK::Pickup.on_reply({ :type => :pickup_grant, :seq => $sent.last[:seq] }) if $grant && $sent.last
      end
    end
    FakeMap = Struct.new(:map_id)
    $game_map = FakeMap.new(5)
    Client = Struct.new(:x) { def connected?; $up; end }
    module PEMK
      def self.log(_m); end
      def self.enabled?; true; end
      def self.self_id; 7; end
      def self.client; Client.new(1); end
      def self.send_message(m); $sent << m if $up; end
      module Config; PICKUP_GRANT_TIMEOUT = 0.2; end
      module InteractAudit
        def self.current_event_tile; [12, 8]; end
        def self.normalize_item(i); i; end
      end
    end
    load File.join(ARGV[0], "004_Pickup.rb")
    P = PEMK::Pickup
    take = -> { P.gated_pickup(:POTION, 1) { |_i, _q| $taken += 1; true } }
    out = {}

    out[:before_login] = P.enforce?
    P.adopt_enforce(true)
    out[:granted] = [take.call, $taken]
    $up = false
    out[:offline] = [P.enforce?, take.call, $taken]
    print out.inspect
  RUBY

  def test_a_dropped_link_leaves_the_ball
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, WORLD], err: %i[child out], &:read)
    assert $?.success?, "pickup runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal false, o[:before_login], "until the server says so, pickups are the engine's"
    assert_equal [true, 1], o[:granted]
    assert_equal [true, false, 1], o[:offline], "gated still, and nothing taken"
  end
end
