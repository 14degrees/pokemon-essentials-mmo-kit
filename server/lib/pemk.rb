# frozen_string_literal: true

# PEMK dedicated server — top-level require. Assumes the load path includes both
# server/lib and the vendored protocol/ dir (see bin/pemk_server.rb).
require "pemk_wire"        # PEMK::Wire (from protocol/)
require "pemk_prng"        # PEMK::Prng (from protocol/) — D7 cross-engine battle PRNG
require "pemk/config"
require "pemk/db"
require "pemk/password"
require "pemk/accounts"
require "pemk/sessions"
require "pemk/characters"
require "pemk/ledger"
require "pemk/inventory"
require "pemk/monsters"
require "pemk/trades"
require "pemk/world_data"
require "pemk/battle_data"
require "pemk/team_audit"
require "pemk/encounter_mint"
require "pemk/encounter_rolls"
require "pemk/catch_calc"
require "pemk/reward_calc"
require "pemk/reward_audit"
require "pemk/monster_stats"
require "pemk/battle_records"
require "pemk/flag_state"
require "pemk/gift_claims"
require "pemk/gift_grants"
require "pemk/monster_blocks"
require "pemk/resim_verdicts"
require "pemk/anomaly_detector"
require "pemk/audit"
require "pemk/position_audit"
require "pemk/pickups"
require "pemk/plain_text"
require "pemk/rate_limiter"
require "pemk/worker_pool"
require "pemk/player_mailbox"
require "pemk/reactor"
require "pemk/server"

module PEMK
  VERSION = "0.1.0-m1"
end
