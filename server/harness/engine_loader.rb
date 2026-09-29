# M4 Layer D D7 part 2 — the ordered engine load for the headless harness.
# Productionized from the STEP-0 spike (109 files, proven load order). Loads the
# battle-mechanics core of Essentials v21.1 from the game repo's Data/Scripts —
# NEVER edits it — plus the compiled GameData .dats. Everything visual is either
# skipped (004_Scene) or satisfied by the inert Battle::Scene shell.

module PEMK
  module Harness
    SCRIPT_GROUPS_HEAD = [
      "001_Settings.rb",
      "002_BattleSettings.rb",
      "003_Game processing/005_Event_Handlers.rb",
      "003_Game processing/006_Event_HandlerCollections.rb",
      "010_Data/001_GameData.rb"
    ].freeze

    PBS_DATA = %w[003_Type 004_Ability 005_Move 006_Item 008_Species
                  010_SpeciesMetrics 012_Ribbon 014_TrainerType 015_Trainer
                  016_Metadata 017_PlayerMetadata].freeze   # Player.new reads Metadata.start_money

    POKEMON_TREE = [
      "014_Pokemon/001_Pokemon-related/001_FormHandlers.rb",
      "014_Pokemon/001_Pokemon.rb",
      "014_Pokemon/002_Pokemon_MegaEvolution.rb",
      "014_Pokemon/003_Pokemon_ShadowPokemon.rb",
      "014_Pokemon/004_Pokemon_Move.rb",
      "014_Pokemon/005_Pokemon_Owner.rb",
      "015_Trainers and player/001_Trainer.rb",
      "015_Trainers and player/004_Player.rb",         # Pokemon#initialize case-matches Player
      "015_Trainers and player/005_Player_Pokedex.rb", # Player.new instantiates Pokedex
      "013_Items/001_Item_Utilities.rb"                # the REAL ItemHandlers module
    ].freeze

    GAMEDATA_CLASSES = %w[Type Ability Move Item Species SpeciesMetrics Ribbon TrainerType Trainer
                          Metadata PlayerMetadata].freeze

    module_function

    def load_engine!(scripts_root)
      ordered = []
      ordered.concat(SCRIPT_GROUPS_HEAD)
      Dir.glob(File.join(scripts_root, "010_Data/001_Hardcoded data/*.rb")).sort.each do |f|
        ordered << f.sub("#{scripts_root}/", "")
      end
      PBS_DATA.each { |f| ordered << "010_Data/002_PBS data/#{f}.rb" }
      ordered.concat(POKEMON_TREE)
      %w[001_Battle 002_Battler 003_Move].each do |dir|
        Dir.glob(File.join(scripts_root, "011_Battle/#{dir}/*.rb")).sort.each do |f|
          ordered << f.sub("#{scripts_root}/", "")
        end
      end
      ordered << "011_Battle/004_Scene/009_Battle_DebugScene.rb"
      ordered << :scene_shell
      ["005_AI", "006_AI MoveEffects", "007_Other battle code", "008_Other battle types"].each do |dir|
        Dir.glob(File.join(scripts_root, "011_Battle/#{dir}/*.rb")).sort.each do |f|
          ordered << f.sub("#{scripts_root}/", "")
        end
      end
      # In-battle item procs (balls, potions — pbRegisterItem consults these; the
      # caught-battle replay throws REAL balls) + the ShadowPokemon reopen of
      # Battle::Battler (pbHyperModeObedience runs on EVERY obedience check).
      # Both must load AFTER the battle engine.
      ordered << "013_Items/003_Item_BattleEffects.rb"
      ordered << "014_Pokemon/001_Pokemon-related/002_ShadowPokemon_Other.rb"

      ordered.each do |rel|
        if rel == :scene_shell
          install_scene_shell
          next
        end
        path = File.join(scripts_root, rel)
        raise "harness: missing engine script #{path}" unless File.exist?(path)

        begin
          Kernel.load(path)
        rescue Exception => e
          raise "harness: engine load failed in #{rel}: #{e.class}: #{e.message}"
        end
      end
      ordered.length - 1
    end

    def load_gamedata!
      GAMEDATA_CLASSES.each { |name| GameData.const_get(name).load }
    end

    # Attributes the OVERWORLD Shadow-Pokémon script adds to Player (never loaded
    # headless) but battle code probes (Item#is_snag_ball?). nil = falsy = no snag
    # machine, which is correct for wild-battle replay.
    def post_patches!
      Player.class_eval do
        attr_accessor :has_snag_machine unless method_defined?(:has_snag_machine)
      end
    end

    # 008_Other battle types (Safari/BugContest) reopen Battle::Scene subclasses at
    # LOAD time. An inert shell (auto-vivifying nested consts) satisfies them;
    # nothing visual ever runs through DebugSceneNoVisuals.
    def install_scene_shell
      Battle.class_eval <<~RUBY
        class Scene
          def self.const_missing(name)
            if name.to_s.end_with?("Mixin")
              const_set(name, Module.new)
            else
              const_set(name, Class.new do
                def initialize(*args); end
                def method_missing(name, *args); nil; end
                def respond_to_missing?(*); true; end
                def self.const_missing(name)
                  if name.to_s.end_with?("Mixin")
                    const_set(name, Module.new)
                  else
                    const_set(name, Class.new(self))
                  end
                end
              end)
            end
          end
          def method_missing(name, *args); nil; end
          def respond_to_missing?(*); true; end
          def pbThrowSuccess; end
          def pbInitSprites; end
        end
      RUBY
    end
  end
end
