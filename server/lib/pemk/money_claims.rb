# frozen_string_literal: true

module PEMK
  # Money authority M1a: the prizes clients claim and what they were judged to be worth,
  # and what each account has been paid for. A claim asked again gets its first verdict;
  # a battle is paid once, a rematch at most once per REMATCH_SEC per contact.
  class MoneyClaims
    NONCE       = (1...(1 << 62)).freeze
    REMATCH_SEC = 20 * 60   # the engine's own phone delay is 20 to 40 minutes
    PAID        = %w[paid suspect].freeze   # verdicts whose battles are paid for

    def initialize(db)
      @db = db
    end

    def self.nonce(value)
      value.is_a?(Integer) && NONCE.cover?(value) ? value : nil
    end

    def self.trainer_key(type, name, version)
      "trainer:#{type}:#{name}:#{version}"
    end

    def self.event_key(map, event)
      "event:#{map}:#{event}"
    end

    # -> the recorded claim (a Hash), or nil
    def find(account_id, nonce)
      @db[:money_claims].where(account_id: account_id, nonce: nonce).first
    end

    def record(account_id, nonce, verdict:, mode:, amount:, accepted:, map:, trainers:, kind: "trainer", now: Time.now)
      @db[:money_claims].insert_conflict.insert(
        account_id: account_id, nonce: nonce, kind: kind, verdict: verdict, mode: mode.to_s,
        amount: amount, accepted: accepted, map: map, trainers: Sequel.pg_jsonb(trainers), created_at: now
      )
    end

    # M1c: a wild battle's foes, as the server minted them for this account - each roll
    # younger than MINT_SEC and never claimed for Pay Day. -> the rolls, or nil when one
    # is missing.
    MINT_SEC = 30 * 60

    def payday_rolls(account_id, pids, now: Time.now)
      rolls = pids.map do |pid|
        @db[:encounter_rolls].where(account_id: account_id, pid: pid, payday_at: nil)
                             .where { created_at > now - MINT_SEC }.order(Sequel.desc(:id)).first
      end
      rolls.all? ? rolls : nil
    end

    def stamp_payday(rolls, now: Time.now)
      @db[:encounter_rolls].where(id: rolls.map { |r| r[:id] }).update(payday_at: now)
    end


    # -> the payout row for +key+, or nil
    def payout(account_id, key)
      @db[:money_payouts].where(account_id: account_id, key: key).first
    end

    # Marks +keys+ paid by +nonce+; a rematch key already paid is paid again (its clock).
    def pay(account_id, keys, nonce, rematch:, now: Time.now)
      keys.each do |key|
        @db[:money_payouts].insert_conflict(target: %i[account_id key],
                                            update: { nonce: nonce, paid_at: now })
                           .insert(account_id: account_id, key: key, nonce: nonce, rematch: rematch, paid_at: now)
      end
    end

    # -> when a rematch contact (+type+, +name+) was last paid, or nil
    def rematch_clock(account_id, type, name)
      prefix = "trainer:#{type}:#{name}:"
      @db[:money_payouts].where(account_id: account_id, rematch: true).select_map(%i[key paid_at])
                         .select { |key, _| key.start_with?(prefix) }.map(&:last).max
    end

    # The first fresh money frame after a claim: its prize reached the ledger.
    def seal(account_id, now: Time.now)
      @db[:money_claims].where(account_id: account_id, sealed_at: nil, voided_at: nil).update(sealed_at: now)
    end

    # A fresh login: a claim still unsealed may be missing from the save that loads - the
    # battle it paid for can be fought again, so its payouts go. -> the claims voided
    def void_unsealed(account_id, now: Time.now)
      rows = @db[:money_claims].where(account_id: account_id, sealed_at: nil, voided_at: nil, verdict: PAID).all
      rows.each do |c|
        @db[:money_payouts].where(account_id: account_id, nonce: c[:nonce]).delete
        @db[:money_claims].where(account_id: account_id, nonce: c[:nonce]).update(voided_at: now)
      end
      rows
    end
  end
end
