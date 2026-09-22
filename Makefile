# Countersign — common tasks. Requires Foundry, Bun, Node 20+ (and the CRE CLI for simulate/e2e).
.PHONY: install test test-contracts test-workflow test-offchain build-workflow local-e2e testnet-e2e api

install:
	cd contracts && npm ci --ignore-scripts
	cd workflows/countersign && bun install
	cd tools/executor && bun install
	cd services/verifier-api && bun install

test: test-contracts test-workflow test-offchain

test-contracts:
	cd contracts && forge test

test-workflow:
	cd workflows/countersign && bun run typecheck && bun test

test-offchain:
	cd tools/executor && bun run typecheck && bun test
	cd services/verifier-api && bun run typecheck && bun test

build-workflow:
	cd workflows/countersign && bunx cre-compile main.ts

local-e2e:
	bash scripts/local-e2e.sh

testnet-e2e:
	bash scripts/testnet-e2e.sh

api:
	cd services/verifier-api && COUNTERSIGN_API_CONFIG=config.json bun src/main.ts
