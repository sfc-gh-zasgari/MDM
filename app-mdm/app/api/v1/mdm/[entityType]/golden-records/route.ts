import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

const TABLES: Record<string, string> = {
  providers: "MDM.MASTER.PROVIDER_GOLDEN_RECORDS",
  recipients: "MDM.MASTER.RECIPIENT_GOLDEN_RECORDS",
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
  const minCluster = Number(sp.get("min_cluster_size") || 1)
  const search = (sp.get("search") || "").trim().toUpperCase()

  const whereClauses = [`CLUSTER_SIZE >= ${minCluster}`]

  if (search) {
    const safe = search.replace(/'/g, "''")
    if (entityType === "providers") {
      whereClauses.push(
        `(UPPER(NAME_PRIMARY_CLEAN) LIKE '%${safe}%' OR NPI LIKE '%${safe}%' OR UPPER(CITY) LIKE '%${safe}%' OR ZIP LIKE '%${safe}%')`
      )
    } else {
      whereClauses.push(
        `(UPPER(FIRST_NAME_CLEAN) LIKE '%${safe}%' OR UPPER(LAST_NAME_CLEAN) LIKE '%${safe}%' OR SSN LIKE '%${safe}%' OR ADDRESS_ZIP LIKE '%${safe}%')`
      )
    }
  }

  const where = whereClauses.join(" AND ")

  try {
    const orderCol = entityType === "providers" ? "QUALITY_SCORE DESC NULLS LAST" : "GOLDEN_ID DESC"
    const rows = await querySnowflake(`
      SELECT * FROM ${table}
      WHERE  ${where}
      ORDER  BY CLUSTER_SIZE DESC, ${orderCol}
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
    console.error(new Date().toISOString(), "[golden-records]", e)
    return Response.json(
      { entity_type: entityType, items: [], total: 0, error: e instanceof Error ? e.message : "Query failed" },
      { status: 500 }
    )
  }
}
