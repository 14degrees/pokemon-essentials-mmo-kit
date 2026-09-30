# frozen_string_literal: true

# Chain C1 - the relayer and its console. A DEDICATED process (never the live server)
# that drains the asset outbox onto the PemkAssets contract (docs/CHAIN-DESIGN.md).
#
# Usage (WSL, from server/; DATABASE_URL set as for the server):
#   bundle exec ruby bin/pemk_chain.rb loop [seconds]     # the daemon: LISTENs for the server's NOTIFY
#   bundle exec ruby bin/pemk_chain.rb run                # one pass over the queue
#   bundle exec ruby bin/pemk_chain.rb status             # the queue, the failed rows
#   bundle exec ruby bin/pemk_chain.rb show <uid>         # a token: its events, and the chain's view
#   bundle exec ruby bin/pemk_chain.rb backfill           # tokens for Pokemon minted before the chain was on
#   bundle exec ruby bin/pemk_chain.rb deploy             # deploy the contract; prints PEMK_CHAIN_CONTRACT
#   bundle exec ruby bin/pemk_chain.rb cap <SPECIES> <n>  # set a species' supply cap on the contract (0 = none)
#   bundle exec ruby bin/pemk_chain.rb retry <event id>   # clear a failed row's backoff so the next pass retries it now
# Env: PEMK_CHAIN (shadow|on) with PEMK_CHAIN_SPECIES / PEMK_CHAIN_SHINY (the policy, as
# the server reads them), and for `on`: PEMK_CHAIN_RPC (http://127.0.0.1:8545),
# PEMK_CHAIN_KEY (the operator's private key, hex - never commit it), PEMK_CHAIN_CONTRACT.

server_root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(server_root, "lib"))
require "sequel"
require "pemk/config"
require "pemk/db"
require "pemk/asset_events"
require "pemk/chain/relayer"

config = PEMK::Config.new
db     = PEMK::DB.connect(config.database_url, max_connections: 2)
log    = ->(m) { puts "#{Time.now.strftime('%H:%M:%S')} #{m}" }
events = PEMK::AssetEvents.new(db, mode: config.chain == :off ? :shadow : config.chain,
                                   species: config.chain_species, shiny: config.chain_shiny, logger: log)
cmd = ARGV.shift

adapter = lambda do
  abort "PEMK_CHAIN=on needs PEMK_CHAIN_RPC, PEMK_CHAIN_KEY and PEMK_CHAIN_CONTRACT" unless config.chain_rpc && config.chain_key && config.chain_contract
  require "pemk/chain/evm"
  PEMK::Chain::Evm.new(rpc: config.chain_rpc, key: config.chain_key, address: config.chain_contract)
end

relayer = lambda do
  abort "PEMK_CHAIN is off: nothing to relay (set shadow or on)" if config.chain == :off
  PEMK::Chain::Relayer.new(events, adapter: (config.chain == :on ? adapter.call : nil), mode: config.chain, logger: log)
end

case cmd
when "loop"
  interval = (ARGV.shift || "15").to_i
  r = relayer.call
  log.call("chain: #{config.chain} - relaying every #{interval}s or on notify (Ctrl-C to stop)")
  trap("INT")  { puts "\nchain: stopping"; exit 0 }
  trap("TERM") { exit 0 }
  r.run(interval: interval, db: db)

when "run"
  t = relayer.call.pass(limit: (ENV["CHAIN_LIMIT"] || 500).to_i)
  log.call("chain: done - #{t[:confirmed]} confirmed / #{t[:shadow]} shadow / #{t[:failed]} failed / #{t[:waiting]} waiting")

when "status"
  c = events.counts
  puts "asset_events: " + %w[pending sent confirmed failed shadow].map { |s| "#{s}=#{c[s] || 0}" }.join(" ")
  puts "asset_tokens: #{db[:asset_tokens].count} (#{db[:asset_tokens].exclude(mint_tx: nil).count} minted on chain)"
  db[:asset_events].where(status: "failed").order(:id).each do |e|
    puts format("  FAILED #%-6d %-9s token %-8d attempts=%d %s", e[:id], e[:kind], e[:token_id], e[:attempts], e[:last_error])
  end

when "show"
  uid = ARGV.shift.to_i
  t = events.token(uid)
  abort "uid #{uid} has no token" unless t
  puts "token #{t[:token_id]}: #{t[:species]} #{t[:reason]}#{t[:shiny] ? ' shiny' : ''} origin=#{t[:origin] || '-'} " \
       "issuer=#{t[:issuer_account_id]} minted=#{t[:mint_tx] || 'not yet'}"
  db[:asset_events].where(asset_kind: t[:asset_kind], asset_id: uid).order(:id).each do |e|
    puts format("  #%-6d %-9s %-9s %s->%s %s %s", e[:id], e[:kind], e[:status], e[:from_account_id] || "-", e[:to_account_id] || "-",
                e[:ref] || "", e[:tx_hash] || e[:last_error] || "")
  end
  if config.chain == :on
    a = adapter.call
    if a.minted?(uid)
      puts "  chain: account=#{a.account_of(uid)} frozen=#{a.frozen?(uid)} holder=#{a.owner_of(uid)}"
    else
      puts "  chain: not minted"
    end
  end

when "backfill"
  n = events.backfill
  log.call("chain: backfill tokenized #{n} Pokemon (queued for the relayer)")

when "deploy"
  abort "deploy needs PEMK_CHAIN_RPC and PEMK_CHAIN_KEY" unless config.chain_rpc && config.chain_key
  require "pemk/chain/evm"
  addr = PEMK::Chain::Evm.deploy(rpc: config.chain_rpc, key: config.chain_key)
  puts "PemkAssets deployed at #{addr}"
  puts "set PEMK_CHAIN_CONTRACT=#{addr}"

when "cap"
  species = ARGV.shift.to_s.upcase
  cap = Integer(ARGV.shift.to_s, exception: false)
  abort "cap <SPECIES> <n>" if species.empty? || cap.nil? || cap.negative?
  a = adapter.call
  tx = a.set_cap(species, cap)
  minted, now_cap = a.supply_of(species)
  puts "#{species}: cap #{now_cap} (#{minted} minted) - #{tx}"

when "retry"
  id = ARGV.shift.to_i
  n = db[:asset_events].where(id: id, status: "failed").update(sent_at: nil)
  puts n.positive? ? "event ##{id} will be retried on the next pass" : "event ##{id} is not failed"

else
  abort "usage: pemk_chain.rb loop [seconds] | run | status | show <uid> | backfill | deploy | cap <SPECIES> <n> | retry <id>"
end
