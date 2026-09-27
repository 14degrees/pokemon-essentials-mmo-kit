#===============================================================================
# PEMK :: Autopilot::VInput  (virtual keys layered over the real Input module)
#-------------------------------------------------------------------------------
# The engine cannot tell a virtual key from a real one: Input.trigger?, press?,
# repeat?, release?, dir4 and dir8 answer for it exactly as for a key on the
# keyboard, and the state advances once per Input.update like the real one. That is
# what lets the autopilot play without window focus - nothing goes through Windows.
#
# Semantics, counted in Input.update steps: trigger? on the first step a key is
# down, press? while it is down, repeat? on the first step and then every
# REPEAT_EVERY steps after REPEAT_DELAY (a held arrow scrolls a menu), release? on
# the step after it comes up.
#===============================================================================
module PEMK
  module Autopilot
    module VInput
      REPEAT_DELAY = 15
      REPEAT_EVERY = 4
      NAMES = %w[USE BACK ACTION SPECIAL UP DOWN LEFT RIGHT JUMPUP JUMPDOWN AUX1 AUX2
                 A B C X Y Z L R SHIFT CTRL ALT F5 F6 F7 F8 F9].freeze
      DIRS  = [["DOWN", 2], ["LEFT", 4], ["RIGHT", 6], ["UP", 8]].freeze

      @held     = {}   # key => steps left, nil = until released
      @down     = {}   # key => steps it has been down (1 on the trigger step)
      @released = {}   # keys that came up on the current step
      @taps     = []   # queued one-step presses, started once their key is fully up

      module_function

      # "USE", "use", "C"... -> the Input constant, or nil for an unknown name.
      def key(name)
        n = name.to_s.upcase
        return nil unless NAMES.include?(n) && Input.const_defined?(n)

        Input.const_get(n)
      end

      def name_of(key)
        NAMES.find { |n| Input.const_defined?(n) && Input.const_get(n) == key }
      end

      def hold(key, steps)
        @held[key] = steps
      end

      def release(key)
        @held.delete(key)
      end

      def release_all
        @held.clear
        @taps.clear
      end

      # A press the engine is guaranteed to see as a new trigger: it waits until the
      # key has been up for a whole step. Holding a key that is still down from the
      # previous press only extends it - which is how two level-up windows in a row
      # left the second one waiting forever.
      def tap(key)
        @taps << key
      end

      # Still held, down and not yet through its release step, or a tap is queued.
      def down?(key)
        @held.key?(key) || @down.key?(key) || @taps.include?(key)
      end

      def held_names
        (@held.keys | @down.keys).map { |k| name_of(k) }.compact
      end

      # Once per Input.update, before the engine reads the keys.
      def step
        @released = {}
        @down.each_key { |k| @released[k] = true unless @held.key?(k) }
        @released.each_key { |k| @down.delete(k) }
        @taps.reject! do |k|
          next false if @held.key?(k) || @down.key?(k) || @released.key?(k)

          @held[k] = 1
          true
        end
        @held.each_key { |k| @down[k] = (@down[k] || 0) + 1 }
        @held.keys.each do |k|
          left = @held[k]
          next if left.nil?

          if left > 1
            @held[k] = left - 1
          else
            @held.delete(k)
          end
        end
      end

      def trigger?(key)
        @down[key] == 1
      end

      def press?(key)
        @down.key?(key)
      end

      def repeat?(key)
        d = @down[key]
        return false unless d

        d == 1 || (d > REPEAT_DELAY && ((d - REPEAT_DELAY) % REPEAT_EVERY).zero?)
      end

      def release?(key)
        @released.key?(key)
      end

      # The most recently pressed direction, as 2/4/6/8, or 0 for none.
      def dir4
        best = 0
        best_steps = nil
        DIRS.each do |name, dir|
          d = @down[Input.const_get(name)]
          next unless d && (best_steps.nil? || d < best_steps)

          best = dir
          best_steps = d
        end
        best
      end
    end
  end
end

if PEMK::Autopilot.active?
  module Input
    class << self
      unless method_defined?(:pemk_ap_orig_trigger)
        alias_method :pemk_ap_orig_input_update, :update
        alias_method :pemk_ap_orig_trigger, :trigger?
        alias_method :pemk_ap_orig_press,   :press?
        alias_method :pemk_ap_orig_repeat,  :repeat?
        alias_method :pemk_ap_orig_release, :release?
        alias_method :pemk_ap_orig_dir4,    :dir4
        alias_method :pemk_ap_orig_dir8,    :dir8

        def update(*args)
          PEMK::Autopilot::VInput.step
          pemk_ap_orig_input_update(*args)
        end

        def trigger?(key)
          pemk_ap_orig_trigger(key) || PEMK::Autopilot::VInput.trigger?(key)
        end

        def press?(key)
          pemk_ap_orig_press(key) || PEMK::Autopilot::VInput.press?(key)
        end

        def repeat?(key)
          pemk_ap_orig_repeat(key) || PEMK::Autopilot::VInput.repeat?(key)
        end

        def release?(key)
          pemk_ap_orig_release(key) || PEMK::Autopilot::VInput.release?(key)
        end

        def dir4
          d = PEMK::Autopilot::VInput.dir4
          d.zero? ? pemk_ap_orig_dir4 : d
        end

        def dir8
          d = PEMK::Autopilot::VInput.dir4
          d.zero? ? pemk_ap_orig_dir8 : d
        end
      end
    end
  end
end
