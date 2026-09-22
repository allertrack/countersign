#!/usr/bin/env bash
# Countersign end to end on the PUBLIC CCIP v2 testnets (Ethereum Sepolia -> Arbitrum Sepolia). No mocks:
#   real OnRamp/OffRamp 2.0.0, real Chainlink committee signatures (public CCIP indexer), a real attestation written by
#   `cre workflow simulate --broadcast` through the CRE MockKeystoneForwarder, and permissionless execution.
#
# Requirements
#   - contracts/.env with PRIVATE_KEY of a FRESH TESTNET-ONLY wallet holding Sepolia ETH (~0.1) and
#     Arbitrum Sepolia ETH (~0.02). Faucets: https://faucets.chain.link
#   - `cre login` done once (CRE simulation needs an authenticated CLI).
#   - Optional: ETHERSCAN_API_KEY in contracts/.env to verify the contracts on both explorers.
#
# Options (env): REDEPLOY=1 (fresh stack), AMOUNT=<wei> (default 5,000 CST), DEMO_HOLD=1 (hold -> guardian release).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.foundry/bin:$HOME/.bun/bin:$HOME/.cre/bin:$PATH"
step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
json() { python -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2" | tr -d '\r'; }
if [[ "${OS:-}" == "Windows_NT" ]]; then export FOUNDRY_CACHE_PATH="$(cygpath -w "$TEMP")\\cs-forge-cache"; fi

cd "$ROOT/contracts"
[[ -f .env ]] || { echo "contracts/.env missing: copy contracts/.env.example and fill PRIVATE_KEY" >&2; exit 1; }
set -a; source .env; set +a
: "${PRIVATE_KEY:?PRIVATE_KEY missing in contracts/.env}"
export SEPOLIA_RPC_URL=${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}
export ARBITRUM_SEPOLIA_RPC_URL=${ARBITRUM_SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}
SEP_RPC=$SEPOLIA_RPC_URL
ARB_RPC=$ARBITRUM_SEPOLIA_RPC_URL
AMOUNT=${AMOUNT:-5000000000000000000000}
ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")

step "0. Preflight for $ADDRESS"
cre whoami >/dev/null 2>&1 || { echo "Run 'cre login' once (browser), then re-run." >&2; exit 1; }
SEP_BAL=$(cast balance "$ADDRESS" --rpc-url "$SEP_RPC")
ARB_BAL=$(cast balance "$ADDRESS" --rpc-url "$ARB_RPC")
echo "Sepolia: $(cast from-wei "$SEP_BAL") ETH   Arbitrum Sepolia: $(cast from-wei "$ARB_BAL") ETH"
python -c "import sys; sys.exit(0 if int('$SEP_BAL') >= 5*10**16 and int('$ARB_BAL') >= 10**16 else 1)" ||
  { echo "Fund the wallet first (>= 0.05 Sepolia ETH, >= 0.01 Arbitrum Sepolia ETH): https://faucets.chain.link" >&2; exit 1; }

VERIFY=()
[[ -n "${ETHERSCAN_API_KEY:-}" ]] && VERIFY=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
run() { forge script script/Countersign.s.sol:CountersignScript "$@" --broadcast --slow; }

# Reuse only a Countersign verifier this wallet owns: an address with code is not enough (it could be anyone's).
deployed() { # chain-id rpc
  [[ -f "deployments/$1.json" ]] || return 1
  local verifier
  verifier=$(json "deployments/$1.json" verifier)
  [[ "$(cast call "$verifier" "typeAndVersion()(string)" --rpc-url "$2" 2>/dev/null)" == '"CountersignVerifier 1.0.0"' ]] &&
    [[ "$(cast call "$verifier" "owner()(address)" --rpc-url "$2" 2>/dev/null | tr 'A-F' 'a-f')" == "$(echo "$ADDRESS" | tr 'A-F' 'a-f')" ]]
}

step "1. Deploy (CRE simulation forwarders) and connect"
if [[ "${REDEPLOY:-0}" == "1" ]] || ! deployed 11155111 "$SEP_RPC" || ! deployed 421614 "$ARB_RPC"; then
  CRE_SIMULATION=true CRE_FORWARDER=0x15fC6ae953E024d975e77382eEeC56A9101f9F88 run --sig "deploy()" --rpc-url "$SEP_RPC" "${VERIFY[@]}"
  CRE_SIMULATION=true CRE_FORWARDER=0xd41263567ddfead91504199b8c6c87371e83ca5d run --sig "deploy()" --rpc-url "$ARB_RPC" "${VERIFY[@]}"
  run --sig "connect(uint256)" 421614 --rpc-url "$SEP_RPC"
  run --sig "connect(uint256)" 11155111 --rpc-url "$ARB_RPC"
else
  echo "Reusing deployments/11155111.json and deployments/421614.json (REDEPLOY=1 to start over)"
fi

step "2. ccipSend $(cast from-wei "$AMOUNT") CST Sepolia -> Arbitrum Sepolia"
run --sig "send(uint256,uint256)" 421614 "$AMOUNT" --rpc-url "$SEP_RPC"
TX=$(python -c "import json;d=json.load(open('broadcast/Countersign.s.sol/11155111/send-latest.json'));print([t['hash'] for t in d['transactions'] if 'ccipSend' in (t.get('function') or '')][0])" | tr -d '\r')
SRC_VERIFIER=$(json deployments/11155111.json verifier)
read -r EVENT_INDEX TX_BLOCK MESSAGE_ID < <(cast receipt "$TX" --rpc-url "$SEP_RPC" --json | python -c "
import json,sys
r=json.load(sys.stdin)
for i,l in enumerate(r['logs']):
    if l['address'].lower()=='${SRC_VERIFIER}'.lower():
        print(i, int(r['blockNumber'],16), l['topics'][1]); break" | tr -d '\r')
[[ -n "${MESSAGE_ID:-}" ]] || { echo "CountersignRequested not found in $TX" >&2; exit 1; }
echo "tx $TX (block $TX_BLOCK), CountersignRequested log #$EVENT_INDEX, messageId $MESSAGE_ID"
echo "CCIP Explorer: https://ccip.chain.link/msg/$MESSAGE_ID"

step "3. Wait for Sepolia finality (the workflow's log trigger is FINALIZED)"
until [[ $(cast block finalized -f number --rpc-url "$SEP_RPC") -ge $TX_BLOCK ]]; do
  printf '.'; sleep 30
done
echo " finalized"

step "4. CRE workflow simulation, broadcasting the attestation to Arbitrum Sepolia"
POLICY_VERSION="testnet-$(date +%Y%m%d)"
python ../scripts/make-config.py deployments ../workflows/countersign/config.testnet.json "$POLICY_VERSION" ../services/verifier-api/config.json
if [[ "${DEMO_HOLD:-0}" == "1" ]]; then
  # Denylist the receiver so the workflow HOLDS the transfer; the guardian releases it below.
  python -c "
import json; p='../workflows/countersign/config.testnet.json'; c=json.load(open(p))
c['policy']['denylist']=['$ADDRESS']; json.dump(c, open(p,'w'), indent=2)"
fi
(cd ../workflows && CRE_ETH_PRIVATE_KEY=$PRIVATE_KEY cre workflow simulate ./countersign -T testnet-settings \
  --non-interactive --trigger-index 0 --evm-tx-hash "$TX" --evm-event-index "$EVENT_INDEX" --broadcast)
DST_VERIFIER=$(json deployments/421614.json verifier)
echo "attestation: $(cast call "$DST_VERIFIER" "getAttestation(bytes32)((uint64,uint8,uint32,uint40,bytes32))" "$MESSAGE_ID" --rpc-url "$ARB_RPC")"

if [[ "${DEMO_HOLD:-0}" == "1" ]]; then
  step "4b. Held: the executor refuses, the guardian reviews and releases"
  (cd ../tools/executor && bun src/cli.ts --source ethereum-testnet-sepolia --tx "$TX") || true
  cast send "$DST_VERIFIER" "releaseHold(bytes32,bytes32)" "$MESSAGE_ID" "$(cast keccak "reviewed: demo")" \
    --private-key "$PRIVATE_KEY" --rpc-url "$ARB_RPC" >/dev/null
  echo "released by guardian $ADDRESS"
fi

step "5. Execute on Arbitrum Sepolia (committee signatures from Chainlink's public indexer + Countersign)"
(cd ../tools/executor && bun src/cli.ts --source ethereum-testnet-sepolia --tx "$TX" --wait --timeout 3600)

step "Done"
echo "Receiver balance on Arbitrum Sepolia: $(cast from-wei "$(cast call "$(json deployments/421614.json token)" "balanceOf(address)(uint256)" "$ADDRESS" --rpc-url "$ARB_RPC" | cut -d' ' -f1)") CST"
echo "Source tx:     https://sepolia.etherscan.io/tx/$TX"
echo "CCIP message:  https://ccip.chain.link/msg/$MESSAGE_ID"
echo "Verifier:      https://sepolia.arbiscan.io/address/$DST_VERIFIER#events"
