require "minitest/autorun"
require "rbconfig"

root  = File.expand_path("..", __dir__)
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk_marshal_scan"

# The client carries its own copy of the Marshal reader (mkxp-z cannot require
# protocol/). Both copies must answer every vector the same way, or the server would
# forward a body the client then refuses, or the other way round.
class MarshalScanPluginTest < Minitest::Test
  PLUGIN = File.expand_path("../../Plugins/PEMK/001_Net/004_MarshalScan.rb", __dir__)

  Point = Struct.new(:x, :y)

  class Holder
    def initialize
      @a = [1, "two", :three, 4.5, 2**70, { k: nil }]
      @b = Point.new(Time.at(0), /re/)
    end
  end

  def vectors
    [Marshal.dump(nil), Marshal.dump([1, [2, [3]]]), Marshal.dump(Holder.new),
     Marshal.dump("é"), Marshal.dump(Hash.new(3)), "".b, "\x04\b[\x04\x00\x00\x00\x40".b,
     Marshal.dump(Holder.new).byteslice(0, 20), "\x04\bo:\x12Shop::Receipt\x06:\n@item[\x00".b]
  end

  def test_both_copies_agree
    runner = <<~'RUBY'
      module PEMK; end
      load ARGV[0]
      vecs = Marshal.load($stdin.read)
      print Marshal.dump(vecs.map { |v| PEMK::MarshalScan.classes(v) })
    RUBY
    got = IO.popen([RbConfig.ruby, "-W0", "-e", runner, PLUGIN], "r+b") do |io|
      io.write(Marshal.dump(vectors))
      io.close_write
      io.read
    end
    assert $?.success?, "plugin scan runner crashed"
    plugin = Marshal.load(got)
    server = vectors.map { |v| PEMK::MarshalScan.classes(v) }
    assert_equal server, plugin
    assert(server.any? { |v, _| v == :bad })
    assert(server.any? { |v, n| v == :ok && !n.empty? })
  end
end
