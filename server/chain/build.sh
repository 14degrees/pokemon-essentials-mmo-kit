#!/usr/bin/env bash
# Compile chain/PemkAssets.sol into chain/PemkAssets.json (abi + bytecode), which the
# relayer deploys and calls. Needs node and the solc npm package (any 0.8.20+):
#   npm install solc@0.8      # once, anywhere; point SOLC_DIR at its node_modules
set -euo pipefail
cd "$(dirname "$0")"
SOLC_DIR="${SOLC_DIR:-./node_modules}"
NODE_PATH="$SOLC_DIR" node - <<'JS'
const solc = require("solc");
const fs = require("fs");
const src = fs.readFileSync("PemkAssets.sol", "utf8");
const input = {
  language: "Solidity",
  sources: { "PemkAssets.sol": { content: src } },
  settings: { optimizer: { enabled: true, runs: 200 },
              outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } }
};
const out = JSON.parse(solc.compile(JSON.stringify(input)));
const errors = (out.errors || []).filter(e => e.severity === "error");
if (errors.length) { console.error(errors.map(e => e.formattedMessage).join("\n")); process.exit(1); }
(out.errors || []).forEach(e => console.warn(e.formattedMessage));
const c = out.contracts["PemkAssets.sol"]["PemkAssets"];
fs.writeFileSync("PemkAssets.json", JSON.stringify({
  contract: "PemkAssets", compiler: solc.version(), abi: c.abi, bytecode: "0x" + c.evm.bytecode.object
}, null, 1) + "\n");
console.log("PemkAssets.json: abi " + c.abi.length + " entries, bytecode " + c.evm.bytecode.object.length / 2 + " bytes (" + solc.version() + ")");
JS
