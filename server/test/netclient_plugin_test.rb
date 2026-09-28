require "minitest/autorun"
require "rbconfig"

# The client reads what the server sent before it closed the link, then the close.
# It used to report the disconnect first: the server's last frames (why it closed
# us, a trade's result) arrived after the disconnect had reset what they apply to.
class NetClientPluginTest < Minitest::Test
  NET = File.expand_path("../../Plugins/PEMK/001_Net", __dir__)

  RUNNER = <<~'RUBY'
    require "socket"
    module PEMK; def self.log(_m); end; end
    %w[001_NetConfig.rb 002_MessageCodec.rb 003_NetClient.rb].each { |f| load File.join(ARGV[0], f) }

    mine, theirs = UNIXSocket.pair
    client = PEMK::NetClient.new
    client.instance_variable_set(:@socket, mine)
    client.instance_variable_set(:@connected, true)
    theirs.write(PEMK::MessageCodec.encode_split({ :type => :trade_result, :ok => true }) +
                 PEMK::MessageCodec.encode_split({ :type => :session_replaced }))
    theirs.close
    sleep 0.05
    print [client.poll.map { |m| m[:type] }, client.connected?].inspect
  RUBY

  def test_the_last_frames_come_before_the_disconnect
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, NET], err: %i[child out], &:read)
    assert $?.success?, "netclient runner crashed:\n#{out}"
    assert_equal "[[:trade_result, :session_replaced, :__disconnected__], false]", out.strip
  end
end
