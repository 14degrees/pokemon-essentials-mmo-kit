# frozen_string_literal: true

require "securerandom"

module PEMK
  # Trainer proof P2 (docs/TRAINER-PROOF-DESIGN.md): the seeds of trainer battles
  # (migration 042). A placement's open seed is the answer however often it is asked; it
  # closes once a battle on it is proven won (P3) or after TTL. Runs on the account's
  # mailbox.
  class TrainerBattles
    SEED_BITS = 63            # a positive signed bigint, as the wild seeds (D7)
    TTL       = 24 * 3600     # an open seed nobody won on expires after a day

    def initialize(db)
      @db = db
    end

    # -> the open seed of (account, placement), made now if there is none.
    def seed_for(account_id, map, event, type, name, version, now: Time.now)
      key = placement(account_id, map, event, type, name, version)
      open = @db[:trainer_battles].where(key.merge(state: "open"))
      open.where { issued_at < now - TTL }.update(state: "expired", closed_at: now)
      seed = open.get(:seed)
      return seed if seed

      seed = new_seed
      @db[:trainer_battles].insert(key.merge(seed: seed, state: "open", issued_at: now))
      seed
    rescue Sequel::UniqueConstraintViolation   # the same placement asked twice at once
      @db[:trainer_battles].where(key.merge(state: "open")).get(:seed)
    end

    # -> the row +seed+ names for +account_id+ (any state), or nil.
    def row_for_seed(account_id, seed)
      @db[:trainer_battles].where(account_id: account_id, seed: seed).first
    end

    private

    def placement(account_id, map, event, type, name, version)
      { account_id: account_id, map_id: map, event_id: event, tr_type: type.to_s,
        tr_name: name.to_s, tr_version: version.to_i }
    end

    def new_seed
      loop do
        s = SecureRandom.random_number(1 << SEED_BITS)
        return s if s.positive?
      end
    end
  end
end
