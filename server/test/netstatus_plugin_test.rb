require "minitest/autorun"
require "rbconfig"

# The server hands an account to a newer login (another window) and tells the old
# socket so. That window must stay offline for good, and say why, instead of
# reconnecting and taking the account back every few seconds.
class NetStatusPluginTest < Minitest::Test
  NETSTATUS = File.expand_path("../../Plugins/PEMK/003_Game/006_NetStatus.rb", __dir__)

  RUNNER = <<~'RUBY'
    $calls = []
    def _INTL(s, *_a); s; end
    module EventHandlers; def self.add(*); end; end
    module PEMK
      def self.log(_m); end
      def self.shutdown; $calls << :shutdown; end
      def self.ensure_started; $calls << :start; end
      def self.client; nil; end
      module Auth; def self.logged_in?; true; end; end
    end
    load ARGV[0]

    ns = PEMK::NetStatus
    lost = ns.instance_variable_get(:@notices).dup
    ns.on_disconnect                     # an ordinary drop schedules a reconnect
    scheduled = !ns.instance_variable_get(:@reconnect_at).nil?

    ns.on_replaced                       # ... but the account was taken elsewhere
    ns.on_disconnect
    ns.tick
    print [scheduled, ns.instance_variable_get(:@reconnect_at), $calls,
           ns.instance_variable_get(:@notices).last.to_s.include?("another window or device")].inspect
  RUBY

  def test_a_replaced_session_stays_offline_and_says_why
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, NETSTATUS], err: %i[child out], &:read)
    assert $?.success?, "netstatus runner crashed:\n#{out}"
    assert_equal "[true, nil, [], true]", out.strip
  end
end
