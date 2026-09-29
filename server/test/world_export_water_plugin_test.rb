require "minitest/autorun"
require "rbconfig"

# Layer B for surfers and divers: the world export marks where a surfer may be (the
# engine's playerPassable? while surfing) and where Dive goes down or comes up
# (terrain_tag's can_dive), since the passability grid counts every water tile as a
# wall; and, for a map below, the map a diver comes up to (the engine's own pick).
class WorldExportWaterPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module GameData
      Tag = Struct.new(:id_number, :can_surf, :waterfall, :can_dive, :bridge, :ignore_passability, :ledge)
      module TerrainTag
        DATA = {
          0 => Tag.new(0, false, false, false, false, false, false),   # None
          5 => Tag.new(5, true, false, true, false, false, false),     # DeepWater
          6 => Tag.new(6, true, false, false, false, false, false),    # Water
          8 => Tag.new(8, true, true, false, false, false, false),     # Waterfall
          15 => Tag.new(15, false, false, false, true, false, false)   # Bridge
        }
      end
      Meta = Struct.new(:id, :dive_map_id)
      module MapMetadata
        ALL = [Meta.new(69, 70), Meta.new(70, nil), Meta.new(72, 70)].freeze
        def self.try_get(id)
          raise "no metadata" if id == 1

          ALL.find { |m| m.id == id }
        end

        def self.each(&block) = ALL.each(&block)
      end
    end
    load ARGV[0]

    # tile id => [terrain id_number, passage, priority]
    tiles = { 1 => [0, 0, 0], 2 => [0, 0x0f, 0], 3 => [6, 0x0f, 0], 4 => [5, 0x0f, 0], 5 => [8, 0x0f, 0],
              6 => [15, 0, 0], 7 => [0, 0x0f, 1], 8 => [0, 0, 1] }
    Tileset = Struct.new(:passages, :priorities, :terrain_tags)
    ts = Tileset.new(Array.new(9) { |i| tiles[i] ? tiles[i][1] : 0 },
                     Array.new(9) { |i| tiles[i] ? tiles[i][2] : 0 },
                     Array.new(9) { |i| tiles[i] ? tiles[i][0] : 0 })
    $data_tilesets = [nil, ts]
    class Grid
      def initialize(layers); @layers = layers; end
      def [](x, y, z); (@layers[z] || {})[[x, y]] || 0; end
    end
    MapStub = Struct.new(:tileset_id, :width, :height, :data)
    ground = { [0, 0] => 1, [1, 0] => 3, [2, 0] => 4, [3, 0] => 4,
               [0, 1] => 3, [1, 1] => 3, [2, 1] => 5, [3, 1] => 1,
               [0, 2] => 3, [1, 2] => 2, [2, 2] => 4, [3, 2] => 1 }
    middle = { [0, 2] => 6, [2, 2] => 6 }                        # a bridge over water, and over deep water
    top    = { [0, 1] => 7, [1, 1] => 8, [3, 0] => 7 }           # rocks on water and on deep water, a lily pad
    sea = MapStub.new(1, 4, 3, Grid.new([ground, middle, top]))
    land = MapStub.new(1, 2, 1, Grid.new([{ [0, 0] => 1, [1, 0] => 2 }]))
    w = PEMK::WorldExport
    print({ sea: w.map_water(sea), land: w.map_water(land),
            dives: [w.dive_map_of(69), w.dive_map_of(70), w.dive_map_of(1), w.dive_map_of(2)],
            surfaces: [w.surface_map_of(70), w.surface_map_of(69), w.surface_map_of(71)] }.inspect)
  RUBY

  def test_water_and_dive_marks
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    # row 0: ground, water, deep water, a rock on deep water (a diver may come up there,
    # no surfer goes there); row 1: a rock on the water, a lily pad on it, a waterfall,
    # ground; row 2: a bridge over water, a wall, a bridge over deep water, ground.
    assert_equal [".wdx", ".ww.", "w.d."], got[:sea], out
    assert_nil got[:land], "a map without water has no grid"
    assert_equal [70, nil, nil, nil], got[:dives]
    assert_equal [69, nil, nil], got[:surfaces], "the first map whose DiveMap it is, as pbSurfacing looks"
  end
end
