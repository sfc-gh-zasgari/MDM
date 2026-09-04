import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

export async function GET(_request: NextRequest) {
  try {
    const results: Record<string, unknown> = {}

    for (const etype of ["providers", "recipients"] as const) {
      const cleanTbl = etype === "providers" ? "MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN" : "MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN"
      const goldenTbl = etype === "providers" ? "MDM.MASTER.PROVIDER_GOLDEN_RECORDS" : "MDM.MASTER.RECIPIENT_GOLDEN_RECORDS"
      const matchTbl = etype === "providers" ? "MDM.MATCHING.PROVIDER_MATCH_RESULTS" : "MDM.MATCHING.RECIPIENT_MATCH_RESULTS"

      try {
        const [sourceRow] = await querySnowflake(`SELECT COUNT(*) AS N FROM ${cleanTbl}`)
        const [goldenRow] = await querySnowflake(`SELECT COUNT(*) AS N FROM ${goldenTbl}`)
        const [mergedRow] = await querySnowflake(`SELECT COUNT(*) AS N FROM ${goldenTbl} WHERE CLUSTER_SIZE > 1`)
        const [reviewRow] = await querySnowflake(`SELECT COUNT(*) AS N FROM ${matchTbl} WHERE ROUTING = 'MANUAL_REVIEW'`)

        results[etype] = {
          source_records: Number(sourceRow?.N ?? 0),
          golden_records: Number(goldenRow?.N ?? 0),
          merged_entities: Number(mergedRow?.N ?? 0),
          pending_review: Number(reviewRow?.N ?? 0),
        }
      } catch {
        results[etype] = { source_records: 0, golden_records: 0, merged_entities: 0, pending_review: 0 }
      }
    }

    return Response.json(results)
  } catch (e) {
    console.error(new Date().toISOString(), "[summary]", e)
    return Response.json(
      { error: e instanceof Error ? e.message : "Failed to fetch summary" },
      { status: 500 }
    )
  }
}
