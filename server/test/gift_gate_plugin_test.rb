require "minitest/autorun"
require "rbconfig"

# Step 6, client half: with the server's gift gate on, an event's pbReceiveItem asks
# first. A grant runs the vanilla gift once and reports it applied; "already claimed"
# gives nothing and lets the event move on; silence leaves the gift owed (in the save)
# until a grant comes, re-sent on every new connection before the bag is flushed; and
# the bag is held back from the request until the applied report is out.
class GiftGatePluginTest < Minitest::Test
  WORLD = File.expand_path("../../Plugins/PEMK/008_World", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $msgs = []; $given = []; $give_ok = true; $script = []
    def _INTL(s, *a); a.each_with_index.reduce(s) { |t, (v, i)| t.sub("{#{i + 1}}", v.to_s) }; end
    def pbMessage(s); $msgs << s; end
    def pbMapInterpreterRunning?; false; end
    def pbUpdateSceneMap; end
    module EventHandlers; def self.add(*); end; end
    module Input; def self.update; end; end
    module Graphics
      # The network pump: each frame delivers the next scripted server frame.
      def self.update
        r = $script.shift
        PEMK::GiftClaim.on_reply(r.call) if r
      end
    end
    class Scene_Map; end
    class PokemonGlobalMetadata; end
    Temp = Struct.new(:in_battle, :message_window_showing, :player_transferring)
    FakeMap = Struct.new(:map_id)
    Item = Struct.new(:id, :name)
    module GameData
      module Item
        def self.try_get(i); %i[TM80 POTION].include?(i.to_sym) ? ::Item.new(i.to_sym, i.to_s) : nil; end
        def self.get(i); try_get(i); end
      end
    end
    class Bag
      attr_accessor :room
      def can_add?(_i, _q); @room != false; end
    end
    class Interpreter
      def initialize(map, event); @map_id = map; @event_id = event; end
      def execute_script(script); eval(script); end
    end
    Client = Struct.new(:up) { def connected?; up; end }
    module PEMK
      @client = Client.new(true)
      def self.log(_m); end
      def self.enabled?; true; end
      def self.self_id; 7; end
      def self.client; @client; end
      def self.send_message(m); $sent << m if @client.up; end
      module Config; GIFT_GRANT_TIMEOUT = 0.3; end
      module Flags; def self.active?; true; end; end
    end
    def pbReceiveItem(item, quantity = 1)   # the vanilla gift
      $given << [item, quantity]
      $held = (PEMK::GiftClaim.holding? rescue nil)
      $give_ok
    end
    load File.join(ARGV[0], "005_GiftClaim.rb")

    G = PEMK::GiftClaim
    $scene = Scene_Map.new
    $game_temp = Temp.new(false, false, false)
    $game_map = FakeMap.new(10)
    $PokemonGlobal = PokemonGlobalMetadata.new
    $bag = Bag.new
    brock = Interpreter.new(10, 3)
    gift = ->(item = ":TM80") { brock.execute_script("pbReceiveItem(#{item})") }
    reqs = -> { $sent.select { |m| m[:type] == :gift_req } }
    out = {}

    # the gate off: vanilla, then the report
    out[:off] = [gift.call, $given.size, $sent.map { |m| m[:type] }]

    G.adopt_gate(true)
    $sent.clear; $given.clear

    # a grant: the vanilla gift runs once, the bag is held back meanwhile, then applied
    $script = [-> { { :type => :gift_grant, :seq => reqs.call.last[:nonce] } }]
    r = gift.call
    req = reqs.call.last
    out[:grant] = [r, $given.dup, $held, G.holding?, [req[:map], req[:event], req[:item], req[:quantity]],
                   $sent.last[:type], $sent.last[:nonce] == req[:nonce]]

    # already claimed: nothing given, the event moves on
    $sent.clear; $given.clear; $msgs.clear
    $script = [-> { { :type => :gift_deny, :seq => reqs.call.last[:nonce], :reason => "already_claimed" } }]
    out[:claimed] = [gift.call, $given.size, $msgs.dup]

    # any other refusal: false, the event's own branch
    $sent.clear; $msgs.clear
    $script = [-> { { :type => :gift_deny, :seq => reqs.call.last[:nonce], :reason => "not_this_gift" } }]
    out[:refused] = [gift.call, $msgs.size]

    # silence: owed, and the event moves on
    $sent.clear; $given.clear; $msgs.clear
    $script = []
    r = gift.call
    owed = $PokemonGlobal.pemk_gifts_owed
    out[:silence] = [r, $given.size, owed.map { |e| e[0, 4] }, reqs.call.size, $msgs.last]

    # a flush on this connection re-sends nothing; a new connection re-sends it first
    G.before_bag_flush
    n1 = reqs.call.size
    G.reset
    G.adopt_gate(true)
    out[:resend] = [n1, reqs.call.size, reqs.call.last[:nonce] == owed[0][4]]

    # its grant comes: added on a free frame, reported, no longer owed
    G.on_reply({ :type => :gift_grant, :seq => owed[0][4] })
    G.tick
    out[:settled] = [$given.dup, $sent.last[:type], $PokemonGlobal.pemk_gifts_owed.size]

    # offline: owed without a word to the server
    $sent.clear; $given.clear
    PEMK.client.up = false
    r = gift.call
    out[:offline] = [r, $sent.size, $PokemonGlobal.pemk_gifts_owed.size]
    PEMK.client.up = true
    G.reset; G.adopt_gate(true)
    G.on_reply({ :type => :gift_deny, :seq => $PokemonGlobal.pemk_gifts_owed[0][4], :reason => "already_claimed" })
    G.tick
    out[:owed_denied] = [$given.size, $PokemonGlobal.pemk_gifts_owed.size]

    # a full bag: vanilla, nothing asked; no running event: vanilla
    $sent.clear; $given.clear
    $bag.room = false
    gift.call
    $bag.room = true
    def pbMapInterpreter; nil; end
    pbReceiveItem(:POTION)
    out[:vanilla] = [$given.size, reqs.call.size]

    # a parallel event gives while another gift waits: the bag stays held for the first
    $sent.clear; $given.clear
    park = Interpreter.new(10, 8)
    inner_hold = nil
    $script = [lambda do
      $script.unshift(-> { { :type => :gift_grant, :seq => reqs.call.last[:nonce] } })
      park.execute_script("pbReceiveItem(:POTION)")
      inner_hold = G.holding?
      { :type => :gift_grant, :seq => reqs.call.first[:nonce] }
    end]
    gift.call
    out[:nested] = [inner_hold, $given.dup, G.holding?, reqs.call.map { |m| m[:event] }]

    # a parallel event's own interpreter names the gift, not the map's
    def pbMapInterpreter; Interpreter.new(10, 99); end
    out[:context] = [Interpreter.new(10, 4).execute_script("PEMK::GiftClaim.context"), G.context]
    print out.inspect
  RUBY

  def run_gate
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, WORLD], err: %i[child out], &:read)
    assert $?.success?, "gift gate runner crashed:\n#{out}"
    eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
  end

  def test_the_gate
    o = run_gate
    assert_equal [true, 1, [:gift_claim]], o[:off]
    assert_equal [true, [[:TM80, 1]], true, false, [10, 3, "TM80", 1], :gift_applied, true], o[:grant]
    assert_equal [true, 0, ["You already received the TM80."]], o[:claimed]
    assert_equal [false, 1], o[:refused]
    assert_equal [true, 0, [[10, 3, "TM80", 1]], 1,
                  "The TM80 will be added to your Bag once the server confirms it."], o[:silence]
    assert_equal [1, 2, true], o[:resend]
    assert_equal [[[:TM80, 1]], :gift_applied, 0], o[:settled]
    assert_equal [true, 0, 1], o[:offline]
    assert_equal [0, 0], o[:owed_denied]
    assert_equal [2, 0], o[:vanilla]
    assert_equal [true, [[:POTION, 1], [:TM80, 1]], false, [3, 8]], o[:nested]
    assert_equal [[10, 4], [10, 99]], o[:context]
  end
end
