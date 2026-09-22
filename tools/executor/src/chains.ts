import { type Chain, arbitrumSepolia, sepolia } from 'viem/chains'

export type ChainInfo = {
	name: string
	chain: Chain
	selector: bigint
	rpcUrl: string
	router: `0x${string}`
}

/** CCIP v2 testnet lanes Countersign is deployed on. RPCs can be overridden with the usual env vars. */
export const CHAINS: Record<string, ChainInfo> = {
	'ethereum-testnet-sepolia': {
		name: 'ethereum-testnet-sepolia',
		chain: sepolia,
		selector: 16015286601757825753n,
		rpcUrl: process.env.SEPOLIA_RPC_URL ?? 'https://ethereum-sepolia-rpc.publicnode.com',
		router: '0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59',
	},
	'ethereum-testnet-sepolia-arbitrum-1': {
		name: 'ethereum-testnet-sepolia-arbitrum-1',
		chain: arbitrumSepolia,
		selector: 3478487238524512106n,
		rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL ?? 'https://sepolia-rollup.arbitrum.io/rpc',
		router: '0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165',
	},
}

export const chainBySelector = (selector: bigint): ChainInfo => {
	const found = Object.values(CHAINS).find((c) => c.selector === selector)
	if (!found) throw new Error(`no chain configured for selector ${selector}`)
	return found
}

export const chainByName = (name: string): ChainInfo => {
	const found = CHAINS[name]
	if (!found) throw new Error(`unknown chain ${name}; expected one of ${Object.keys(CHAINS).join(', ')}`)
	return found
}

/** Chainlink's public CCIP v2 indexers (same defaults as @chainlink/ccip-sdk). */
export const TESTNET_INDEXER_URLS = [
	'https://indexer-1.testnet.ccip.chain.link',
	'https://indexer-2.testnet.ccip.chain.link',
]
export const MAINNET_INDEXER_URLS = ['https://indexer-1.ccip.chain.link', 'https://indexer-2.ccip.chain.link']
