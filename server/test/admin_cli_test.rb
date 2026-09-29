require "minitest/autorun"
require "open3"
require "rbconfig"
require "sequel"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/sessions"

# The operator's moderation console (bin/pemk_admin.rb), run the way the operator runs
# it: a ban ends the account's sessions at once and stays on record once lifted.
class AdminCliTest < Minitest::Test
  CLI = File.expand_path("../bin/pemk_admin.rb", __dir__)

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @id = @db[:accounts].insert(email: "cheat@t.co", password_hash: "x", status: "active", created_at: Time.now)
    PEMK::Sessions.new(@db).issue(@id)
  end

  def teardown
    @db&.disconnect
  end

  def admin(*args)
    out, status = Open3.capture2e({ "PEMK_OPERATOR" => "tester" }, RbConfig.ruby, CLI, *args.map(&:to_s))
    [out, status.success?]
  end

  def test_ban_show_and_lift
    out, ok = admin("ban", "cheat@t.co", "--hours", 2, "duplicating", "items")
    assert ok, out
    assert_match(/banned account #{@id} \(cheat@t\.co\) until .+ - duplicating items/, out)
    ban = @db[:account_bans].where(account_id: @id).first
    assert_equal "tester", ban[:banned_by]
    assert_in_delta (Time.now + 7200).to_f, ban[:ends_at].to_f, 60
    assert(@db[:sessions].where(account_id: @id).all? { |s| s[:revoked] }, "its sessions end at once")

    assert_match(/1 ban\(s\) in force/, admin("bans").first)
    assert_match(/BANNED until/, admin("show", @id).first)

    out, ok = admin("unban", @id)
    assert ok, out
    assert_match(/lifted 1 ban\(s\)/, out)
    out, = admin("show", "cheat@t.co")
    assert_match(/not banned/, out)
    assert_match(/lifted .+ by tester/, out)
    assert_match(/is not banned/, admin("unban", @id).first)
  end

  def test_a_ban_without_an_end
    out, ok = admin("ban", @id)
    assert ok, out
    assert_match(/until lifted/, out)
    assert_nil @db[:account_bans].where(account_id: @id).get(:ends_at)
  end

  def test_what_it_refuses
    out, ok = admin("ban", "nobody@t.co")
    refute ok
    assert_match(/no account nobody@t\.co/, out)
    out, ok = admin("ban", @id, "--days", "x")
    refute ok
    assert_match(/--days needs a whole number/, out)
    out, ok = admin("frobnicate")
    refute ok
    assert_match(/Usage/, out)
    assert_equal 0, @db[:account_bans].count
  end
end
