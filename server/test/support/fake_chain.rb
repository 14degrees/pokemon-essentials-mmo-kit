# frozen_string_literal: true

# An in-memory PemkAssets for the relayer's and the reconciler's tests: the same reads
# and writes as Chain::Evm, the same refusals, and a hand on the state (to tamper).
class FakeChain
  attr_reader :tokens, :calls

  def initialize
    @tokens = {}
    @calls  = []
    @fail_next = nil
  end

  def fail_next!(msg) = @fail_next = msg
  def minted?(id)     = @tokens.key?(id)
  def account_of(id)  = @tokens.fetch(id)[:account]
  def frozen?(id)     = @tokens.fetch(id)[:frozen]
  def total_supply    = @tokens.size

  def mint(id, account:, kind:, species:, shiny:, origin:)
    boom!
    raise "minted" if minted?(id)

    @tokens[id] = { account: account, kind: kind, species: species, shiny: shiny, origin: origin, frozen: false }
    tx(:mint, id)
  end

  def move(id, to_account:, ref:)
    boom!
    raise "frozen" if @tokens.fetch(id)[:frozen]

    @tokens[id][:account] = to_account
    tx(:move, id)
  end

  def set_frozen(id, frozen, reason:)
    boom!
    @tokens.fetch(id)[:frozen] = frozen
    tx(:freeze, id)
  end

  private

  def boom!
    return unless @fail_next

    m = @fail_next
    @fail_next = nil
    raise m
  end

  def tx(kind, id)
    @calls << [kind, id]
    "0x#{kind}#{id}#{@calls.size}"
  end
end
