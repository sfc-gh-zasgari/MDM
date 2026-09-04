import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

const TABLES: Record<string, string> = {
  providers: "MDM.MATCHING.PROVIDER_MATCH_RESULTS",
  recipients: "MDM.MATCHING.RECIPIENT_MATCH_RESULTS",
}

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ entityType: string }> }
) {
  const { entityType } = await params
  const table = TABLES[entityType]
  if (!table) {
    return Response.json({ error: "Invalid entity type" }, { status: 400 })
  }

  const sp = request.nextUrl.searchParams
  const limit = Math.min(Number(sp.get("limit") || 50), 200)
  const offset = Number(sp.get("offset") || 0)
  const matchType = sp.get("match_type") || ""
  const minScore = Number(sp.get("min_score") || 0)
  const maxScore = Number(sp.get("max_score") || 1)
  const search = (sp.get("search") || "").trim().toUpperCase()

  const whereClauses = ["1=1"]
  if (matchType) whereClauses.push(`MATCH_TYPE = '${matchType.replace(/'/g, "''")}'`)
  if (minScore > 0) whereClauses.push(`HYBRID_SCORE >= ${minScore}`)
  if (maxScore < 1) whereClauses.push(`HYBRID_SCORE <= ${maxScore}`)
  if (search) {
    const safe = search.replace(/'/g, "''")
    whereClauses.push(`(UPPER(NAME_A) LIKE '%${safe}%' OR UPPER(NAME_B) LIKE '%${safe}%')`)
  }

  const where = whereClauses.join(" AND ")

  try {
    const rows = await querySnowflake(`
      SELECT * FROM ${table}
      WHERE  ${where}
      ORDER  BY HYBRID_SCORE ASC, ROW_A
      LIMIT  ${limit} OFFSET ${offset}
    `)
    const [countRow] = await querySnowflake(`SELECT COUNT(*) AS N FROM ${table} WHERE ${where}`)
    const total = Number(countRow?.N ?? 0)

    const items = rows.map((r: Record<string, unknown>) => {
      const out: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(r)) {
        out[k.toLowerCase()] = v
      }
      return out
    })

    return Response.json({ entity_type: entityType, items, total })
  } catch (e) {
    console.error(new Date().toISOString(), "[match-pairs]", e)
    return Response.json(
      { entity_type: entityType, items: [], total: 0, error: e instanceof Error ? e.message : "Query failed" },
      { status: 500 }
    )
  }
}
