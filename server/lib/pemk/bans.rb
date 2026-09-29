# frozen_string_literal: true

module PEMK
  # Moderation: account suspensions (migration 041). The operator sets and lifts them
  # (bin/pemk_admin.rb); the server refuses a banned account at login and at a resume,
  # and closes the connection of one that is playing.
  class Bans
    REASON_MAX = 200   # what the player is shown of the reason

    def initialize(db)
      @db = db
    end

    # -> the ban in force on +account_id+ (the latest row), or nil.
    def active(account_id, now: Time.now)
      in_force(now).where(account_id: account_id).order(Sequel.desc(:created_at), Sequel.desc(:id)).first
    end

    # -> the accounts among +account_ids+ with a ban in force.
    def banned_among(account_ids, now: Time.now)
      return [] if account_ids.empty?

      in_force(now).where(account_id: account_ids).distinct.select_map(:account_id)
    end

    # -> the new ban's id. +ends_at+ nil: until lifted.
    def ban(account_id, reason:, by:, ends_at: nil, now: Time.now)
      @db[:account_bans].insert(account_id: account_id, reason: reason.to_s[0, 2000], banned_by: by.to_s[0, 64],
                                created_at: now, ends_at: ends_at)
    end

    # Lifts every ban in force on +account_id+. -> how many.
    def lift(account_id, by:, now: Time.now)
      in_force(now).where(account_id: account_id).update(lifted_at: now, lifted_by: by.to_s[0, 64])
    end

    def history(account_id)
      @db[:account_bans].where(account_id: account_id).order(:created_at, :id).all
    end

    # -> the bans in force, oldest first.
    def in_force_list(now: Time.now)
      in_force(now).order(:created_at, :id).all
    end

    # What a refused client is told: when the ban ends (epoch seconds, nil: until
    # lifted) and the reason, cut short.
    def self.notice(ban)
      { until: ban[:ends_at]&.to_i, note: ban[:reason].to_s[0, REASON_MAX] }
    end

    private

    def in_force(now)
      @db[:account_bans].where(lifted_at: nil).where(Sequel.|({ ends_at: nil }, Sequel.expr(:ends_at) > now))
    end
  end
end
