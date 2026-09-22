#!/usr/bin/env python3
"""Builds the `countersign` workflow config (and optionally the verifier API config) from deployment files.

usage: make-config.py <deployments-dir> <workflow-config-out> <policy-version> [<api-config-out>]

Reads <deployments-dir>/11155111.json (Ethereum Sepolia) and 421614.json (Arbitrum Sepolia) as written by
`forge script script/Countersign.s.sol --sig "deploy()"`. Both chains are sources and destinations of each other.
"""
import json
import os
import sys

ONRAMPS = {
    # CCIP v2 OnRamps (docs.chain.link CCIP directory, verified onchain with typeAndVersion()).
    "ethereum-testnet-sepolia": ["0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777"],
    "ethereum-testnet-sepolia-arbitrum-1": ["0x6B9a7cF69F90Ae2659bfe3069fba5Aa308A48cC4"],
}
CHAIN_IDS = {"ethereum-testnet-sepolia": "11155111", "ethereum-testnet-sepolia-arbitrum-1": "421614"}
E18 = 10**18


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    deployments_dir, out, version = sys.argv[1:4]
    api_out = sys.argv[4] if len(sys.argv) > 4 else None
    d = {name: json.load(open(os.path.join(deployments_dir, f"{cid}.json"))) for name, cid in CHAIN_IDS.items()}
    names = list(CHAIN_IDS)

    config = {
        "sources": [{"chainSelectorName": n, "verifier": d[n]["verifier"], "onRamps": ONRAMPS[n]} for n in names],
        "destinations": [{"chainSelectorName": n, "verifier": d[n]["verifier"], "gasLimit": "400000"} for n in names],
        "token": {
            "mode": "burnMint",
            # Each side pre-mints 1,000,000 CST to the deployer (see Countersign.s.sol).
            "canonicalSupply": str(2_000_000 * E18),
            "deployments": [{"chainSelectorName": n, "token": d[n]["token"]} for n in names],
        },
        "policy": {
            "version": version,
            "supplyTolerance": "0",
            "maxWindowOutflow": str(50_000 * E18),
            "maxTransfersPerSender": 3,
            "denylist": [],
        },
        "sweep": {"schedule": "0 */2 * * * *", "lookbackBlocks": 100, "maxMessages": 3},
        "sentinel": {
            "schedule": "30 */5 * * * *",
            "guards": [
                {
                    "chainSelectorName": n,
                    "guard": d[n]["rateLimitGuard"],
                    "pools": [{"pool": d[n]["pool"], "remoteChainSelectorNames": [m for m in names if m != n]}],
                    "gasLimit": "600000",
                }
                for n in names
            ],
        },
    }
    with open(out, "w") as f:
        json.dump(config, f, indent=2)
    print("wrote", out)

    if api_out:
        api = {"chains": [{"name": n, "verifier": d[n]["verifier"], "resolver": d[n]["resolver"]} for n in names]}
        with open(api_out, "w") as f:
            json.dump(api, f, indent=2)
        print("wrote", api_out)


if __name__ == "__main__":
    main()
