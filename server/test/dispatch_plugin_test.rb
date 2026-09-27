require "minitest/autorun"
require "rbconfig"

# Every frame from the server passes through Dispatch.handle before its handler.
# Names in it come from other players and end up in pbMessage, which runs codes;
# a charset names a file to load. Both are cleaned there, whatever the server did.
class DispatchPluginTest < Minitest::Test
  DISPATCH = File.expand_path("../../Plugins/PEMK/003_Game/004_Dispatch.rb", __dir__)

  def run_frames(frames)
    code = <<~RUBY
      $got = []
      module PEMK
        module Remotes; def self.apply_pos(m); $got << m; end; end
        module Trade; def self.on_message(m); $got << m; end; end
        module Challenge; def self.on_message(m); $got << m; end; end
      end
      load #{DISPATCH.inspect}
      frames = Marshal.load([ARGV[0]].pack("H*"))
      frames.each { |f| PEMK::Dispatch.handle(f) }
      print [Marshal.dump($got)].pack("m0")
    RUBY
    arg = Marshal.dump(frames).unpack1("H*")
    out = IO.popen([RbConfig.ruby, "-W0", "-e", code, arg], err: %i[child out], &:read)
    assert $?.success?, "dispatch runner crashed:\n#{out}"
    Marshal.load(out.unpack1("m0"))
  end

  def test_a_name_reaches_the_handlers_without_codes
    got = run_frames([
      { type: :trade_invite, from: 2, to: 1, trade_id: "t", name: "\\ch[51,0,A]Eve<b>" },
      { type: :challenge, from: 2, to: 1, name: "\\se[x]" + "y" * 40 },
      { type: :challenge_decline, from: 2, to: 1, name: "\\<>" }
    ])
    assert_equal "ch[51,0,A]Eveb", got[0][:name]
    assert_equal "se[x]yyyyyyyyyyy", got[1][:name]
    refute got[2].key?(:name)
  end

  def test_presence_keeps_a_plain_charset_and_drops_a_path
    got = run_frames([
      { type: :pos, id: 2, map: 1, x: 1, y: 1, name: "Bob", char: "trainer_POKEMONTRAINER_Red" },
      { type: :pos, id: 2, map: 1, x: 1, y: 1, char: "../../Titles/title" }
    ])
    assert_equal "Bob", got[0][:name]
    assert_equal "trainer_POKEMONTRAINER_Red", got[0][:char]
    refute got[1].key?(:char)
  end

  def test_frames_without_player_text_pass_untouched
    frame = { type: :trade_accept, from: 2, to: 1, trade_id: "t" }
    assert_equal [frame], run_frames([frame])
  end
end
