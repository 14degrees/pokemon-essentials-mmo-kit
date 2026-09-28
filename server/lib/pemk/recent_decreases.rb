# frozen_string_literal: true

module PEMK
  # Item authority E4: what left each account's possession in the last minute, and how
  # many of those units were unexplained ones (the open debts they settled).
  #
  # An item used in battle leaves the bag before the server hears what it was used for:
  # the bag snapshot that shows a ball gone can land before the catch it was thrown in.
  # With this, the server judges the throw against the possession as it was before it.
  # In memory, per server; a restart forgets a minute of it, which only makes a check
  # stricter for that minute.
  class RecentDecreases
    WINDOW = 60

    def initialize(window: WINDOW)
      @window = window
      @mutex  = Mutex.new
      @by     = {}   # [account_id, item] => [[at, units, settled], ...]
    end

    # +down+ { item => units gone }, +settled+ { item => open debts those units settled }.
    def note(account_id, down, settled, now: mono)
      return if down.empty?

      @mutex.synchronize do
        down.each { |item, n| (@by[[account_id, item]] ||= []) << [now, n, settled[item].to_i] }
        prune(now) if @by.size > 1024
      end
    end

    # -> [units gone, of which unexplained] for +item+ within the window.
    def recent(account_id, item, now: mono)
      @mutex.synchronize do
        list = (@by[[account_id, item]] || []).select { |at, _, _| now - at <= @window }
        [list.sum { |_, n, _| n }, list.sum { |_, _, s| s }]
      end
    end

    private

    def prune(now)
      @by.delete_if do |_, list|
        list.reject! { |at, _, _| now - at > @window }
        list.empty?
      end
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
