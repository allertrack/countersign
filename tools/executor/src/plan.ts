import type { Address, Hex } from 'viem'
import { COUNTERSIGN_VERSION_TAG } from './abi'

/** One verifier result as served by Chainlink's CCIP v2 indexer (`/v1/verifierresults/{messageId}`). */
export type IndexerResult = {
	ccvData: Hex
	verifierDestAddress: Address
	verifierSourceAddress?: Address
}

type IndexerResponse = {
	success?: boolean
	results?: { verifierResult: { ccv_data: Hex; verifier_dest_address: Address; verifier_source_address?: Address } }[]
}

/** Parses an indexer response body; an unverified message yields no results. */
export const parseIndexerResponse = (body: IndexerResponse): IndexerResult[] =>
	body.success
		? (body.results ?? []).map(({ verifierResult: vr }) => ({
				ccvData: vr.ccv_data,
				verifierDestAddress: vr.verifier_dest_address,
				verifierSourceAddress: vr.verifier_source_address,
			}))
		: []

/** Races the indexers and returns the first successful answer (like @chainlink/ccip-sdk `fetchVerifications`). */
export const fetchIndexerResults = async (
	messageId: Hex,
	indexerUrls: string[],
	fetcher: typeof fetch = fetch,
): Promise<IndexerResult[]> => {
	try {
		return await Promise.any(
			indexerUrls.map(async (base) => {
				const res = await fetcher(`${base.replace(/\/+$/, '')}/v1/verifierresults/${messageId}`)
				if (!res.ok) throw new Error(`${base}: HTTP ${res.status}`)
				return parseIndexerResponse((await res.json()) as IndexerResponse)
			}),
		)
	} catch {
		return []
	}
}

export type ExecutionPlan = {
	ccvs: Address[]
	verifierResults: Hex[]
	/** Required CCVs with no result yet (execution would fail). */
	missing: Address[]
}

/**
 * Pairs every required CCV with its verifierResults. Countersign CCVs need only their version tag (their proof is the
 * attestation stored onchain); every other CCV's data comes from the indexer.
 */
export const planExecution = (
	requiredCCVs: readonly Address[],
	indexerResults: IndexerResult[],
	countersignCCVs: ReadonlySet<string>,
): ExecutionPlan => {
	const plan: ExecutionPlan = { ccvs: [], verifierResults: [], missing: [] }
	for (const ccv of requiredCCVs) {
		const key = ccv.toLowerCase()
		if (countersignCCVs.has(key)) {
			plan.ccvs.push(ccv)
			plan.verifierResults.push(COUNTERSIGN_VERSION_TAG)
			continue
		}
		const result = indexerResults.find((r) => r.verifierDestAddress.toLowerCase() === key)
		if (result) {
			plan.ccvs.push(ccv)
			plan.verifierResults.push(result.ccvData)
		} else {
			plan.missing.push(ccv)
		}
	}
	return plan
}
