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

  try {
    const rows = await querySnowflake(`
      SELECT m.*, c.DISPLAY_NAME AS MATCH_TYPE_DISPLAY
      FROM ${table} m
      LEFT JOIN MDM.MATCHING.MATCH_RULES_CONFIG c
        ON c.MATCH_TYPE = m.MATCH_TYPE AND c.ENTITY_TYPE = '${entityType}'
      WHERE m.ROUTING = 'MANUAL_REVIEW'
      ORDER BY m.HYBRID_SCORE DESC
      LIMIT ${limit} OFFSET ${offset}
    `)
    const [countRow] = await querySnowflake(
      `SELECT COUNT(*) AS N FROM ${table} WHERE ROUTING = 'MANUAL_REVIEW'`
    )
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
    console.error(new Date().toISOString(), "[review-queue]", e)
    return Response.json(
      { entity_type: entityType, items: [], total: 0, error: e instanceof Error ? e.message : "Query failed" },
      { status: 500 }
    )
  }
}
