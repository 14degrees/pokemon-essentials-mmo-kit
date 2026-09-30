# frozen_string_literal: true

require "json"
require "sequel"
Sequel.extension :pg_json   # Sequel.pg_jsonb for the payloads (the server's DB loads it too; a console may not)

module PEMK
  # Chain C1 - the asset outbox (docs/CHAIN-DESIGN.md). The server owns every Pokemon
  # (monsters, monster_transfers); the chain is a RECEIPT of what the server proved, and
  # this class is the only seam between the two. It never talks to a node: it writes
  # rows, in the transaction that mints or moves the Pokemon, and NOTIFYs the relayer
  # (bin/pemk_chain.rb), which drains them in id order. So a committed swap always has
  # its receipt queued, a rolled-back one never does, and a dead node delays nothing
  # but the receipt.
  #
  # THE POLICY - which Pokemon get a token (asset_tokens, token id = uid):
  #   * shiny   - a shiny the server minted itself and saw caught (origin wild_caught,
  #               its encounter roll shiny). A client's word alone never makes one.
  #   * species - a species the operator lists (the legendaries), from ANY origin; the
  #               token records that origin, so a client-made one is visible on chain.
  # Everything else stays a plain registry row. Runs under the owning account's
  # PlayerMailbox like the registry itself.
  class AssetEvents
    CHANNEL = "pemk_assets"       # NOTIFY: an event to relay (the relayer LISTENs)
    KIND    = "monster"
    KINDS   = %w[mint transfer freeze unfreeze].freeze
    STATUSES = %w[pending sent confirmed failed shadow].freeze

    attr_reader :mode

    def initialize(db, mode: :shadow, species: [], shiny: true, logger: nil)
      @db      = db
      @mode    = mode                                   # :shadow | :on (the server writes the same rows)
      @species = Array(species).map { |s| s.to_s.upcase }.freeze
      @shiny   = shiny
      @log     = logger || ->(_m) {}
    end

    # -> :shiny | :species | nil - why the policy takes this Pokemon, if it does.
    def reason_for(species:, origin:, shiny:)
      return :shiny if @shiny && shiny == true && origin.to_s == "wild_caught"
      return :species if @species.include?(species.to_s.upcase)

      nil
    end

    # A fresh mint (inside mint_batch's transaction, after the registry insert). Writes
    # the token row and its mint event when the policy takes it. A replayed mint never
    # gets here (the registry insert conflicts first); a second call for the same uid
    # writes nothing (the token's primary key). -> reason | nil
    def tokenize(uid, account_id, species:, origin:, shiny:, now: Time.now)
      reason = reason_for(species: species, origin: origin, shiny: shiny)
      return nil unless reason

      inserted = @db[:asset_tokens].insert_conflict.returning(:asset_id).insert(
        asset_kind: KIND, asset_id: uid, token_id: uid, reason: reason.to_s, species: species.to_s,
        origin: origin&.to_s, shiny: shiny == true, issuer_account_id: account_id, created_at: now
      )
      return nil if inserted.empty?

      event("mint", uid, from: nil, to: account_id, ref: nil, now: now,
                         payload: { species: species.to_s, origin: origin&.to_s, shiny: shiny == true, reason: reason.to_s })
      @log.call("chain: account #{account_id} uid#{uid} #{species} tokenized (#{reason}#{origin ? ", #{origin}" : ''})" \
                "#{@mode == :shadow ? ' (shadow)' : ''}")
      reason
    end

    # An ownership move (inside the swap's transaction, after every CAS matched). Only a
    # tokenized uid gets an event; the rest of the trade is the registry's business.
    def transfer(uid, from:, to:, ref:, now: Time.now)
      return false unless tokenized?(uid)

      event("transfer", uid, from: from, to: to, ref: ref.to_s, now: now)
      true
    end

    # A quarantine (freeze) or a pardon (unfreeze): the token stays where it is, marked.
    def freeze(uid, account_id, reason:, now: Time.now)
      return false unless tokenized?(uid)

      event("freeze", uid, from: account_id, to: account_id, ref: reason.to_s, now: now)
      true
    end

    def unfreeze(uid, account_id, reason:, now: Time.now)
      return false unless tokenized?(uid)

      event("unfreeze", uid, from: account_id, to: account_id, ref: reason.to_s, now: now)
      true
    end

    def tokenized?(uid)
      !@db[:asset_tokens].where(asset_kind: KIND, asset_id: uid).empty?
    end

    def token(uid)
      @db[:asset_tokens].where(asset_kind: KIND, asset_id: uid).first
    end

    # Pokemon the policy takes that were minted before the chain was on (or before the
    # species was listed): a token row and a mint event for each, in uid order, each in
    # its own transaction. Provenance and shininess come from the registry and the roll
    # the mint claimed, exactly as at mint time. -> count tokenized
    def backfill(now: Time.now, limit: nil)
      ds = @db[:monsters]
           .left_join(:asset_tokens, asset_id: :id, asset_kind: KIND)
           .left_join(:encounter_rolls, claimed_monster_uid: Sequel[:monsters][:id])
           .where(Sequel[:asset_tokens][:asset_id] => nil)
           .where(Sequel[:monsters][:status] => %w[active quarantined])
           .select(Sequel[:monsters][:id].as(:uid), Sequel[:monsters][:owner_account_id], Sequel[:monsters][:species],
                   Sequel[:monsters][:origin], Sequel[:monsters][:status], Sequel[:encounter_rolls][:shiny])
           .order(Sequel[:monsters][:id])
      ds = ds.limit(limit) if limit
      count = 0
      ds.all.each do |m|
        @db.transaction do
          reason = tokenize(m[:uid], m[:owner_account_id], species: m[:species], origin: m[:origin],
                                                            shiny: m[:shiny] == true, now: now)
          next unless reason

          freeze(m[:uid], m[:owner_account_id], reason: "quarantined", now: now) if m[:status] == "quarantined"
          count += 1
        end
      end
      count
    end

    # --- the relayer's side ---------------------------------------------------

    # The next events to relay, oldest first. A failed row is retried in its place, so
    # the order the registry wrote is the order the chain sees.
    def pending(limit: 100)
      @db[:asset_events].where(status: %w[pending failed]).order(:id).limit(limit).all
    end

    def mark_sent(id, tx_hash, now: Time.now)
      @db[:asset_events].where(id: id).update(status: "sent", tx_hash: tx_hash, sent_at: now,
                                              attempts: Sequel[:attempts] + 1, last_error: nil)
    end

    def mark_confirmed(id, tx_hash, now: Time.now)
      row = @db[:asset_events].where(id: id).first
      return unless row

      @db.transaction do
        @db[:asset_events].where(id: id).update(status: "confirmed", tx_hash: tx_hash, confirmed_at: now,
                                                sent_at: row[:sent_at] || now, last_error: nil,
                                                attempts: row[:status] == "sent" ? Sequel[:attempts] : Sequel[:attempts] + 1)
        if row[:kind] == "mint"
          @db[:asset_tokens].where(asset_kind: row[:asset_kind], asset_id: row[:asset_id])
                            .update(mint_tx: tx_hash, minted_at: now)
        end
      end
    end

    def mark_failed(id, error, now: Time.now)
      @db[:asset_events].where(id: id).update(status: "failed", last_error: error.to_s[0, 500],
                                              attempts: Sequel[:attempts] + 1, sent_at: now)
    end

    # Shadow: the row is stamped without a chain (so the queue empties and the log shows
    # what `on` would have sent).
    def mark_shadow(id, now: Time.now)
      @db[:asset_events].where(id: id).update(status: "shadow", confirmed_at: now)
    end

    def counts
      @db[:asset_events].group_and_count(:status).to_hash(:status, :count)
    end

    private

    def event(kind, uid, from:, to:, ref:, now:, payload: {})
      @db[:asset_events].insert(kind: kind, asset_kind: KIND, asset_id: uid, token_id: uid,
                                from_account_id: from, to_account_id: to, ref: ref,
                                payload: Sequel.pg_jsonb(payload), status: "pending", created_at: now)
      # Inside a transaction Postgres delivers the NOTIFY at commit, and not at all on a
      # rollback - which is exactly the receipt's contract.
      @db.notify(CHANNEL) rescue nil
    end
  end
end
