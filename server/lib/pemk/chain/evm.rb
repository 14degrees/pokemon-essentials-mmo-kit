# frozen_string_literal: true

require "json"
require "eth"

module PEMK
  module Chain
    # The PemkAssets contract over JSON-RPC (the `eth` gem): any EVM chain - a local
    # Hardhat/Anvil node, a testnet, a private chain. One key, the operator's, signs
    # everything; the contract refuses every other sender. Every write waits for its
    # receipt and raises on a revert, so the relayer's stamp means mined and succeeded.
    class Evm
      class Reverted < StandardError; end

      ARTIFACT = File.expand_path("../../../chain/PemkAssets.json", __dir__)
      GAS      = 400_000

      attr_reader :address, :client

      def self.artifact(path = ARTIFACT)
        JSON.parse(File.read(path))
      end

      # -> the new contract's address.
      def self.deploy(rpc:, key:, artifact: ARTIFACT)
        art = artifact(artifact)
        client = Eth::Client.create(rpc)
        contract = Eth::Contract.from_bin(name: art["contract"], bin: art["bytecode"], abi: art["abi"])
        address = client.deploy_and_wait(contract, sender_key: Eth::Key.new(priv: key), gas_limit: 3_000_000)
        raise "deploy failed" unless address
        address
      end

      def initialize(rpc:, key:, address:, artifact: ARTIFACT)
        art = self.class.artifact(artifact)
        @client   = Eth::Client.create(rpc)
        @key      = Eth::Key.new(priv: key)
        @address  = address
        @contract = Eth::Contract.from_abi(name: art["contract"], address: address, abi: art["abi"])
      end

      def operator
        @key.address.to_s
      end

      # --- reads ---
      def minted?(id)       = @client.call(@contract, "exists", id) == true
      def account_of(id)    = @client.call(@contract, "accountOf", id)
      def frozen?(id)       = @client.call(@contract, "frozen", id) == true
      def supply_of(species) = @client.call(@contract, "supplyOf", species.to_s)
      def owner_of(id)      = @client.call(@contract, "ownerOf", id)
      def total_supply      = @client.call(@contract, "totalSupply")
      ASSET_TYPES = %w[uint64 uint8 bool bool string string].freeze   # the contract's Asset struct, in order

      # -> {account:, kind:, shiny:, frozen:, species:, origin:}. Decoded by hand: the gem's
      # `call` cannot decode a struct return in every release (0.5.13 returns nil).
      def asset_of(id)
        selector = Eth::Util.bin_to_hex(Eth::Util.keccak256("assetOf(uint256)")[0, 4])
        data = "0x" + selector + Eth::Util.bin_to_hex(Eth::Abi.encode(["uint256"], [id]))
        raw = @client.eth_call({ to: @address, data: data })["result"].to_s   # the gem adds the block tag
        raise Reverted, "assetOf(#{id}) returned nothing" if raw.length < 66

        # A struct with strings is returned as a dynamic tuple: one head word (its offset,
        # 0x20) and then the tuple body, whose string offsets are relative to the body.
        account, kind, shiny, frozen, species, origin = Eth::Abi.decode(ASSET_TYPES, "0x" + raw[66..])
        { account: account, kind: kind, shiny: shiny, frozen: frozen, species: species, origin: origin }
      end

      # --- writes (mined, succeeded, or raise) ---
      def mint(id, account:, kind:, species:, shiny:, origin:)
        transact("mint", id, account, kind, species.to_s, shiny == true, origin.to_s)
      end

      def move(id, to_account:, ref:)
        transact("move", id, to_account, ref.to_s)
      end

      def set_frozen(id, frozen, reason:)
        transact("setFrozen", id, frozen == true, reason.to_s)
      end

      def set_cap(species, cap)
        transact("setCap", species.to_s, cap)
      end

      private

      # The gem's transact_and_wait hides a node's revert reason behind its own
      # decoding bug (0.5.17), so the steps run here: sign and send, wait, read the
      # receipt. A node that refuses the transaction up front (Hardhat, Anvil: a revert
      # simulated at submission) raises RpcError with the reason; one that mines a failed
      # transaction shows status 0x0. Either way the stamp means mined AND succeeded.
      def transact(fn, *args)
        hash = @client.transact(@contract, fn, *args, sender_key: @key, gas_limit: GAS)
        hash = hash.first if hash.is_a?(Array)
        raise Reverted, "#{fn}: no transaction hash" unless hash.is_a?(String)

        @client.wait_for_tx(hash)
        receipt = @client.eth_get_transaction_receipt(hash)["result"]
        raise Reverted, "#{fn} reverted (#{hash})" unless receipt && receipt["status"] == "0x1"

        hash
      rescue IOError => e   # the gem's RpcError (an IOError in every release) carries the node's reason
        raise Reverted, "#{fn} reverted: #{e.message[0, 300]}"
      end
    end
  end
end
