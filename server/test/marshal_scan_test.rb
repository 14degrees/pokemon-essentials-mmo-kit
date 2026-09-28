require "minitest/autorun"

root  = File.expand_path("..", __dir__)
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk_marshal_scan"

# The Marshal reader the server runs on a relayed body before forwarding it (and the
# client before loading it): it names every class the bytes refer to without building
# any, and refuses bytes whose lengths, links or nesting do not hold together.
class MarshalScanTest < Minitest::Test
  S = PEMK::MarshalScan
  PARTY = %w[Pokemon Pokemon::Move Pokemon::Owner Mail].freeze

  class Mon
    def initialize
      @species = :PIKACHU
      @level   = 12
      @name    = "Pikaé"
      @moves   = [Move.new, Move.new]
      @iv      = { HP: 31, ATTACK: 0 }
      @owner   = nil
      @big     = 2**80
      @neg     = -70_000
      @ratio   = 0.25
    end
  end

  class Move
    def initialize
      @id = :THUNDERSHOCK
      @pp = 30
    end
  end

  Point = Struct.new(:x, :y)

  class Custom
    def marshal_dump; [1, 2]; end
    def marshal_load(_a); end
  end

  class Tagged < String; end

  module Mark; end

  def names(obj)
    verdict, found = S.classes(Marshal.dump(obj))
    assert_equal :ok, verdict, found.inspect
    found.sort
  end

  def test_plain_data_names_no_class
    data = [nil, true, false, 0, 1, -1, 122, -123, 255, 65_536, -2**31, 2**70, -2**70, 1.5, -0.0,
            "text", "été", :sym, :sym, { a: 1, "b" => [2, 3] }, [[[]]], "".b]
    assert_equal [], names(data)
  end

  def test_a_shared_object_is_a_link
    s = "shared"
    assert_equal [], names([s, s, { k: s }])
  end

  def test_a_hash_with_a_default
    h = Hash.new(5)
    h[:a] = 1
    assert_equal [], names(h)
  end

  def test_objects_are_named
    assert_equal ["MarshalScanTest::Mon", "MarshalScanTest::Move"], names([Mon.new, Mon.new])
  end

  def test_every_way_a_class_can_appear_is_named
    ext = +"x"
    ext.extend(Mark)
    assert_equal ["MarshalScanTest::Point"], names(Point.new(1, "a"))
    assert_equal ["MarshalScanTest::Custom"], names(Custom.new)
    assert_equal ["MarshalScanTest::Tagged"], names(Tagged.new("t"))
    assert_equal ["MarshalScanTest::Mark"], names(ext)
    assert_equal ["Time"], names(Time.at(0))
    assert_equal ["Regexp"], names(/a+b/i)
    assert_equal ["String"], names(String)
    assert_equal ["Kernel"], names(Kernel)
  end

  def test_refusal_follows_the_allow_list
    mon = Marshal.dump([Mon.new])
    assert_nil S.refusal(mon, ["MarshalScanTest::Mon", "MarshalScanTest::Move"])
    assert_equal "class MarshalScanTest::Move", S.refusal(mon, ["MarshalScanTest::Mon"])
    assert_nil S.refusal(Marshal.dump([1, "a", :b]), PARTY)
  end

  # A body naming a class no party holds: refused before anything is built.
  def test_an_unexpected_class_is_refused
    payload = "\x04\bo:\x12Shop::Receipt\x06:\n@item[\x00".b
    assert_equal "class Shop::Receipt", S.refusal(payload, PARTY)
  end

  def test_malformed_bytes_are_refused
    good = Marshal.dump([Mon.new, "tail"])
    {
      "empty"             => "".b,
      "wrong version"     => "\x04\x07[\x00".b,
      "truncated"         => good.byteslice(0, good.bytesize - 3),
      "trailing bytes"    => good + "0",
      "a count past the end" => "\x04\b[\x04\x00\x00\x00\x40".b,   # an array of 2**30 elements
      "a length past the end" => "\x04\b\"\x02\xff\xff".b,
      "a dangling link"   => "\x04\b[\x06@\x07".b,
      "a dangling symbol" => "\x04\bo;\x07\x00".b,
      "an unknown type"   => "\x04\bZ".b
    }.each do |label, bytes|
      verdict, = S.classes(bytes)
      assert_equal :bad, verdict, label
      refute_nil S.refusal(bytes, PARTY), label
    end
  end

  def test_nesting_is_bounded
    deep = []
    cur = deep
    (S::MAX_DEPTH + 2).times { cur << (nxt = []); cur = nxt }
    assert_equal [:bad, "nested too deep"], S.classes(Marshal.dump(deep))
    ok = []
    cur = ok
    (S::MAX_DEPTH - 2).times { cur << (nxt = []); cur = nxt }
    assert_equal :ok, S.classes(Marshal.dump(ok))[0]
  end

  def test_only_byte_strings_are_read
    assert_equal :bad, S.classes(nil)[0]
    assert_equal :bad, S.classes(42)[0]
  end
end
