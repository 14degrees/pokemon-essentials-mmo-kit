#===============================================================================
# PEMK :: Autopilot :: SaveHold  (debug only — the save that never landed)
#-------------------------------------------------------------------------------
# `hold_saves on` keeps the save blob from reaching the server while everything else
# still flows, so a scenario can kill the game in the window before its next save and
# check what the server gives back. Inert until the verb is used.
#===============================================================================
module PEMK
  module Autopilot
    module SaveHold
      @on = false

      def self.on
        @on
      end

      def self.on=(v)
        @on = (v == true)
        PEMK.log("autopilot: save blobs #{@on ? 'held' : 'released'}")
      end
    end
  end
end

if defined?(PEMK::Sync) && PEMK::Sync.respond_to?(:push_blob) &&
   !PEMK::Sync.respond_to?(:pemk_ap_push_blob)
  class << PEMK::Sync
    alias_method :pemk_ap_push_blob, :push_blob
    def push_blob(save_file, force: false)
      return :offline if PEMK::Autopilot::SaveHold.on   # the retry loop keeps it armed

      pemk_ap_push_blob(save_file, force: force)
    end
  end
end
