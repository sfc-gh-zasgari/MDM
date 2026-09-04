import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

const TABLES: Record<string, string> = {
  providers: "MDM.MATCHING.PROVIDER_MATCH_RESULTS",
  recipients: "MDM.MATCHING.RECIPIENT_MATCH_RESULTS",
}

export async function GET(
  _request: NextRequest,
  { params }: { params: Promise<{ entityType: string }> }
) {
  const { entityType } = await params
  const table = TABLES[entityType]
  if (!table) {
    return Response.json({ error: "Invalid entity type" }, { status: 400 })
  }

  try {
    // Get actual match counts
    const rows = await querySnowflake(`
      SELECT MATCH_TYPE, ROUTING, COUNT(*) AS N
      FROM   ${table}
      GROUP  BY MATCH_TYPE, ROUTING
      ORDER  BY N DESC
    `)

    // Get all configured rules for this entity (includes tiers with 0 matches)
    const configRows = await querySnowflake(`
      SELECT MATCH_TYPE, DISPLAY_NAME, TIER, SORT_ORDER
      FROM MDM.MATCHING.MATCH_RULES_CONFIG
      WHERE ENTITY_TYPE = '${entityType}'
      ORDER BY SORT_ORDER
    `)

    const routingCounts: Record<string, number> = { AUTO_MERGE: 0, MANUAL_REVIEW: 0, AUTO_REJECT: 0 }
    const ruleCounts: Record<string, number> = {}
    let total = 0

    // Initialize all configured rules with 0
    for (const cfg of configRows) {
      ruleCounts[String(cfg.MATCH_TYPE)] = 0
    }

    for (const r of rows) {
      const n = Number(r.N)
      const routing = String(r.ROUTING)
      const rule = String(r.MATCH_TYPE)
      routingCounts[routing] = (routingCounts[routing] ?? 0) + n
      ruleCounts[rule] = (ruleCounts[rule] ?? 0) + n
      total += n
    }

    // Build display name lookup from config
    const displayNames: Record<string, string> = {}
    for (const cfg of configRows) {
      displayNames[String(cfg.MATCH_TYPE)] = String(cfg.DISPLAY_NAME)
    }

    const rules = Object.entries(ruleCounts)
      .sort((a, b) => b[1] - a[1])
      .map(([rule_name, count]) => ({
        rule_name,
        display_name: displayNames[rule_name] ?? rule_name,
        count,
        pct: total > 0 ? Math.round((1000 * count) / total) / 10 : 0,
      }))

    return Response.json({
      entity_type: entityType,
      total_pairs: total,
      routing: routingCounts,
      rules,
    })
  } catch (e) {
    console.error(new Date().toISOString(), "[match-stats]", e)
    return Response.json(
      { entity_type: entityType, total_pairs: 0, routing: {}, rules: [], error: e instanceof Error ? e.message : "Query failed" },
      { status: 500 }
    )
  }
}
