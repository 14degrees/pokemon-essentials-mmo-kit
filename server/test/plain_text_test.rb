require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "pemk/plain_text"

# Names one player shows another go through the game's message box, which runs
# codes. What is left must print as plain text.
class PlainTextTest < Minitest::Test
  T = PEMK::PlainText

  def test_an_honest_name_is_unchanged
    assert_equal "Ash", T.name("Ash")
    assert_equal "Élodie", T.name("Élodie")
    assert_equal "Mr. Mime", T.name("Mr. Mime")
  end

  def test_codes_lose_their_backslash_and_brackets
    assert_equal "ch[51,0,Yes]Eve", T.name("\\ch[51,0,Yes]Eve")
    assert_equal "c2=FF00FF00cRed", T.name("<c2=FF00FF00>\\cRed")
    assert_equal "Ash", T.name("A\u0000s\nh")
    assert_equal "Ash", T.name("\u202eAsh")        # no right-to-left override
  end

  def test_it_is_bounded_and_never_empty
    assert_equal "x" * T::NAME_MAX, T.name("x" * 500)
    assert_nil T.name("\\<>")
    assert_nil T.name("   ")
    assert_nil T.name(nil)
    assert_nil T.name(42)
  end

  def test_bad_bytes_do_not_raise
    assert_equal "Ash", T.name("A\xFFsh".b)
  end

  def test_a_charset_is_a_plain_file_name
    assert_equal "trainer_POKEMONTRAINER_Red", T.charset("trainer_POKEMONTRAINER_Red")
    assert_equal "NPC 01", T.charset("NPC 01")
    assert_nil T.charset("../Titles/title")
    assert_nil T.charset("C:\\Windows\\x")
    assert_nil T.charset("[8]anim")
    assert_nil T.charset("")
    assert_nil T.charset(:boy)
  end
end
