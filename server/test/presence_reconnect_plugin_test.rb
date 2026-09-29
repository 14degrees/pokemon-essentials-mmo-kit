require "minitest/autorun"
require "rbconfig"

# Presence sends a position only when it changed since the last one it sent. That memory
# outlived the socket: after a reconnect the same tile was never sent, so the new
# connection had no position, and the gift gate judged a request against the position
# stored with the last save. A new connection now starts with no memory of the old one.
class PresenceReconnectPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []
    module Graphics; def self.frame_count; 0; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m[:type]; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.self_id; 7; end
      def self.log(_m); end
      def self.send_message(m); $sent << m[:type]; end
      module Config; HEARTBEAT_FRAMES = 30; end
    end
    Pl = Struct.new(:map_id, :x, :y, :direction, :move_speed, :character_name) do
      def moving?; false; end
    end
    $game_player = Pl.new(5, 3, 4, 2, 3, "boy")
    $game_map = Object.new
    $player = nil
    load File.join(ARGV[0], "003_Game", "003_Presence.rb")
    load File.join(ARGV[0], "006_Sync", "001_Sync.rb")

    PEMK::Presence.emit(:pos)
    PEMK::Presence.emit(:pos)     # the same tile: not sent again on this socket
    first = $sent.dup
    PEMK::Sync.reset              # a new connection
    PEMK::Presence.emit(:pos)     # the same tile, for the new socket
    print [first, $sent].inspect
  RUBY

  def test_a_new_connection_gets_the_position_again
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "presence runner crashed:\n#{out}"
    assert_equal "[[:pos], [:pos, :pos]]", out.strip
  end
end
