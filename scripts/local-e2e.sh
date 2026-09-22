#!/usr/bin/env bash
# Countersign end to end on local anvil forks of the live CCIP v2 testnets (Ethereum Sepolia -> Arbitrum Sepolia).
#
#   1. fork both chains            4. CRE simulation of the `countersign` workflow (requires `cre login` once)
#   2. deploy + connect the stack  5. execute on the destination OffRamp and check the mint
#   3. ccipSend 5,000 CST
#
# Uses anvil's well-known test account #0. It only ever touches the local forks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACTS="$ROOT/contracts"
WORKFLOWS="$ROOT/workflows"
export PATH="$HOME/.foundry/bin:$HOME/.bun/bin:$HOME/.cre/bin:$PATH"

ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SEP_RPC=http://127.0.0.1:8545
ARB_RPC=http://127.0.0.1:8546
SEP_FORK_URL=${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}
ARB_FORK_URL=${ARBITRUM_SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}
SEP_MOCK_FORWARDER=0x15fC6ae953E024d975e77382eEeC56A9101f9F88
ARB_MOCK_FORWARDER=0xd41263567ddfead91504199b8c6c87371e83ca5d
ARB_OFFRAMP=0xC93218EB7B778bC0c13E5296140C8E4Fa1C440DA
COMMITTEE_RESOLVER=0x8f3ee3c77D2B27c32306a89D367654F959Db223D
AMOUNT=${AMOUNT:-5000000000000000000000}
VERSION_TAG=0xc5160001

step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
json() { python -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2" | tr -d '\r'; }

if [[ "${OS:-}" == "Windows_NT" ]]; then export FOUNDRY_CACHE_PATH="$(cygpath -w "$TEMP")\\cs-forge-cache"; fi

# Arbitrum Sepolia: the official rollup RPC serves finalized state; some public nodes prune it within minutes.
step "1. Forks"
# Always fresh forks: public RPCs are not archive nodes, so an old fork loses access to its pinned state.
start_fork() { # port chain-id url
  if cast chain-id --rpc-url "http://127.0.0.1:$1" >/dev/null 2>&1; then
    echo "port $1 is busy: stop the previous anvil first (e.g. 'pkill anvil' or 'taskkill //IM anvil.exe //F')" >&2; exit 1
  fi
  anvil --fork-url "$3" --port "$1" --chain-id "$2" --silent >/dev/null 2>&1 &
  disown
  for _ in $(seq 1 60); do cast chain-id --rpc-url "http://127.0.0.1:$1" >/dev/null 2>&1 && return; sleep 1; done
  echo "anvil on port $1 did not start" >&2; exit 1
}
start_fork 8545 11155111 "$SEP_FORK_URL"
start_fork 8546 421614 "$ARB_FORK_URL"

step "2. Deploy and connect"
cd "$CONTRACTS"
export PRIVATE_KEY=$ANVIL_KEY
# Fork deployments keep the real chain ids, so keep them apart from the public testnet ones.
export DEPLOYMENTS_DIR=deployments-local
run() { # prints the summary lines; on failure prints the whole forge output and stops
  local out
  if ! out=$(forge script script/Countersign.s.sol:CountersignScript "$@" --broadcast --slow 2>&1); then
    echo "$out" >&2; exit 1
  fi
  echo "$out" | grep -E "deployed|Connected|messageId|0x[0-9a-f]{64}$" || true
}
# The simulator's MockKeystoneForwarder delivers no workflow metadata, hence CRE_SIMULATION=true.
CRE_SIMULATION=true CRE_FORWARDER=$SEP_MOCK_FORWARDER run --sig "deploy()" --rpc-url $SEP_RPC
CRE_SIMULATION=true CRE_FORWARDER=$ARB_MOCK_FORWARDER run --sig "deploy()" --rpc-url $ARB_RPC
run --sig "connect(uint256)" 421614 --rpc-url $SEP_RPC
run --sig "connect(uint256)" 11155111 --rpc-url $ARB_RPC

step "3. ccipSend $AMOUNT wei of CST Sepolia -> Arbitrum Sepolia"
run --sig "send(uint256,uint256)" 421614 "$AMOUNT" --rpc-url $SEP_RPC
TX=$(python -c "import json;d=json.load(open('broadcast/Countersign.s.sol/11155111/send-latest.json'));print([t['hash'] for t in d['transactions'] if 'ccipSend' in (t.get('function') or '')][0])" | tr -d '\r')
SRC_VERIFIER=$(json "$DEPLOYMENTS_DIR/11155111.json" verifier)
read -r EVENT_INDEX EVENT_DATA < <(cast receipt "$TX" --rpc-url $SEP_RPC --json | python -c "
import json,sys
r=json.load(sys.stdin)
for i,l in enumerate(r['logs']):
    if l['address'].lower()=='${SRC_VERIFIER}'.lower():
        print(i, l['data']); break" | tr -d '\r')
[[ -n "${EVENT_DATA:-}" ]] || { echo "CountersignRequested not found in $TX" >&2; exit 1; }
ENCODED=$(cast decode-abi "f()(uint64,bytes)" "$EVENT_DATA" | sed -n 2p)
MESSAGE_ID=$(cast keccak "$ENCODED")
echo "tx=$TX  CountersignRequested index=$EVENT_INDEX  messageId=$MESSAGE_ID"

step "4. CRE simulation (countersign workflow)"
# Relative paths: absolute ones break under Windows app-container path redirection.
python ../scripts/make-config.py "$DEPLOYMENTS_DIR" ../workflows/countersign/config.local.json local-e2e
cd "$WORKFLOWS"
if ! cre whoami >/dev/null 2>&1; then
  echo "CRE simulation needs a one-time 'cre login' (browser). Then re-run this script, or run:"
  echo "  cd workflows && CRE_ETH_PRIVATE_KEY=$ANVIL_KEY cre workflow simulate ./countersign -T local-settings \\"
  echo "     --non-interactive --trigger-index 0 --evm-tx-hash $TX --evm-event-index $EVENT_INDEX --broadcast"
  exit 2
fi
CRE_ETH_PRIVATE_KEY=$ANVIL_KEY cre workflow simulate ./countersign -T local-settings --non-interactive \
  --trigger-index 0 --evm-tx-hash "$TX" --evm-event-index "$EVENT_INDEX" --broadcast

step "5. Execute on the Arbitrum Sepolia OffRamp"
cd "$CONTRACTS"
DST_VERIFIER=$(json "$DEPLOYMENTS_DIR/421614.json" verifier)
DST_RESOLVER=$(json "$DEPLOYMENTS_DIR/421614.json" resolver)
DST_TOKEN=$(json "$DEPLOYMENTS_DIR/421614.json" token)
cast call "$DST_VERIFIER" "getAttestation(bytes32)((uint64,uint8,uint32,uint40,bytes32))" "$MESSAGE_ID" --rpc-url $ARB_RPC
# Local-only: stand in for Chainlink's committee, whose signatures a fork cannot produce.
cast rpc anvil_setCode $COMMITTEE_RESOLVER "$(forge inspect script/local/LocalCommitteeStub.sol:LocalCommitteeStub deployedBytecode)" --rpc-url $ARB_RPC >/dev/null
CCVS=$(cast call $ARB_OFFRAMP "getCCVsForMessage(bytes)(address[],address[],uint8)" "$ENCODED" --rpc-url $ARB_RPC | head -1)
RESULTS=$(python -c "
ccvs='$CCVS'.strip('[]').split(', ')
print('[' + ','.join('$VERSION_TAG' if c.lower()=='$DST_RESOLVER'.lower() else '0xdeadbeef' for c in ccvs) + ']')" | tr -d '\r')
echo "required CCVs: $CCVS"
cast send $ARB_OFFRAMP "execute(bytes,address[],bytes[],uint32)" "$ENCODED" "$CCVS" "$RESULTS" 0 \
  --private-key $ANVIL_KEY --rpc-url $ARB_RPC >/dev/null
STATE=$(cast call $ARB_OFFRAMP "getExecutionState(bytes32)(uint8)" "$MESSAGE_ID" --rpc-url $ARB_RPC)
RECEIVER=$(cast wallet address --private-key $ANVIL_KEY)
echo "execution state: $STATE (2 = SUCCESS, 3 = FAILURE)"
echo "receiver balance on Arbitrum Sepolia: $(cast call "$DST_TOKEN" "balanceOf(address)(uint256)" "$RECEIVER" --rpc-url $ARB_RPC)"
