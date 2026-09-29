# frozen_string_literal: true

require "json"

module PEMK
  # Trainer proof P3 (docs/TRAINER-PROOF-DESIGN.md, review H2): a replay proves a battle
  # was won with the team the record says - which is the client's word. Each Pokemon of
  # that team must be one the server knows for this account: registered (a uid), owned,
  # not quarantined, its first-sight lock kept (IVs, shiny, gender - audit item 5) and no
  # more EXP than the server has seen (D6). Database only: runs in the replay tool.
  module ProofChecks
    STATS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze
    IV_TRAINED = 31   # Hyper Training raises an IV to this, the one legal change

    module_function

    # -> [:ok | :unprovable | :refuted, reason | nil]
    def player_team(db, account_id, record)
      frames = Array(record.is_a?(Hash) && record[:init].is_a?(Hash) ? record[:init][:player] : nil).compact
      return [:unprovable, "no player team in the record"] if frames.empty?

      unprovable = nil
      frames.each_with_index do |f, i|
        uid = f.is_a?(Hash) ? f[:uid] : nil
        unless uid.is_a?(Integer)
          unprovable ||= "player #{i}: a Pokemon the server has not registered yet"
          next
        end
        why = pokemon(db, account_id, uid, f)
        return [:refuted, "player #{i} (uid #{uid}): #{why}"] if why
      end
      unprovable ? [:unprovable, unprovable] : [:ok, nil]
    end

    # -> why this frame is not the server's Pokemon +uid+ of +account_id+, or nil.
    def pokemon(db, account_id, uid, frame)
      mon = db[:monsters].where(id: uid).first
      return "not this account's" unless mon && mon[:owner_account_id] == account_id
      return "#{mon[:status]}, not active" unless mon[:status] == "active"

      if (lock = db[:monster_blocks].where(uid: uid).first)
        why = kept_lock(lock, frame)
        return why if why
      end
      seen = db[:monster_stats].where(uid: uid).get(:exp)
      exp = frame[:exp]
      return "EXP #{exp}, more than the #{seen} the server has seen" if seen && exp.is_a?(Integer) && exp > seen

      nil
    end

    def kept_lock(lock, frame)
      locked = hash_of(lock[:ivs])
      ivs = frame[:iv].is_a?(Hash) ? frame[:iv] : {}
      STATS.each do |s|
        want = locked[s]
        got  = ivs[s] || ivs[s.to_sym]
        next if want.nil? || got == want || got == IV_TRAINED

        return "IV #{s} #{got.inspect}, locked at #{want}"
      end
      return "shiny changed" if (frame[:shiny] == true) != (lock[:shiny] == true)
      return "gender changed" if !lock[:gender].nil? && frame[:gender] != lock[:gender]

      nil
    end

    # A jsonb column as a Hash: JSON text without the pg_json extension (the replay tool's
    # plain connection), a delegate with it.
    def hash_of(value)
      return JSON.parse(value) if value.is_a?(String)

      value.respond_to?(:to_hash) ? value.to_hash : {}
    rescue JSON::ParserError
      {}
    end
  end
end
