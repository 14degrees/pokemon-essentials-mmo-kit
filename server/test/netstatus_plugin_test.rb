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

  DISPATCH = File.expand_path("../../Plugins/PEMK/003_Game/004_Dispatch.rb", __dir__)
  AUTHUI   = File.expand_path("../../Plugins/PEMK/004_Persist/003_AuthUI.rb", __dir__)

  # Moderation: the operator banned the account. A :banned frame (or a resume refused as
  # banned) leaves the window offline for good with the notice; the reason is the
  # operator's text, printed without the codes a message box would run.
  BAN_RUNNER = <<~'RUBY'
    $calls = []
    def _INTL(s, *a); a.each_with_index.reduce(s) { |acc, (v, i)| acc.gsub("{#{i + 1}}", v.to_s) }; end
    module EventHandlers; def self.add(*); end; end
    module PEMK
      def self.log(_m); end
      def self.shutdown; $calls << :shutdown; end
      def self.ensure_started; $calls << :start; end
      def self.client; nil; end
      module Auth; def self.logged_in?; true; end; end
    end
    ARGV.each { |f| load f }

    ns = PEMK::NetStatus
    out = {}
    out[:dated] = ns.ban_text({ until: 1_790_000_000, note: "speed hack" })
    out[:coded] = ns.ban_text({ until: nil, note: "\\ch[51,2]<b>trade\u200Bspam</b>\n" })
    out[:bare]  = ns.ban_text({})
    out[:login] = PEMK::AuthUI.friendly({ reason: "banned", until: nil, note: "botting" })
    PEMK::Dispatch.handle({ type: :banned, until: nil, note: "botting" })
    ns.on_disconnect
    ns.tick
    out[:after] = [ns.instance_variable_get(:@reconnect_at), $calls, ns.instance_variable_get(:@notices).last]
    print out.inspect
  RUBY

  def test_a_banned_window_stays_offline_and_says_why
    out = IO.popen([RbConfig.ruby, "-W0", "-e", BAN_RUNNER, DISPATCH, NETSTATUS, AUTHUI], err: %i[child out], &:read)
    assert $?.success?, "ban runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    local = Time.at(1_790_000_000).strftime("%Y-%m-%d %H:%M")
    assert_equal "This account is suspended until #{local}. Reason: speed hack", got[:dated]
    assert_equal "This account is suspended. Reason: ch[51,2]btradespam/b", got[:coded]
    assert_equal "This account is suspended.", got[:bare]
    assert_equal "this account is suspended (botting)", got[:login]
    assert_equal [nil, [], "This account is suspended. Reason: botting"], got[:after]
  end
end
