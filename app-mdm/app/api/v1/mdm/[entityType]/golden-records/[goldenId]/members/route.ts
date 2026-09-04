import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

const LABELS_TABLE: Record<string, string> = {
  providers: "MDM.MATCHING.PROV_LABELS",
  recipients: "MDM.MATCHING.RECIP_LABELS",
}

const CLEAN_TABLE: Record<string, string> = {
  providers: "MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN",
  recipients: "MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN",
}

export async function GET(
  _request: NextRequest,
  { params }: { params: Promise<{ entityType: string; goldenId: string }> }
) {
  const { entityType, goldenId } = await params
  const labelsTable = LABELS_TABLE[entityType]
  const cleanTable = CLEAN_TABLE[entityType]

  if (!labelsTable || !cleanTable) {
    return Response.json({ error: "Invalid entity type" }, { status: 400 })
  }

  try {
    const orderBy = entityType === "providers"
      ? "c.ROW_ID"
      : "c.ROW_ID"

    const rows = await querySnowflake(`
      SELECT c.*
      FROM ${cleanTable} c
      INNER JOIN ${labelsTable} l ON c.ROW_ID = l.NODE
      WHERE l.LABEL = ${goldenId}
      ORDER BY ${orderBy}
    `)

    const items = rows.map((r: Record<string, unknown>) => {
      const out: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(r)) {
        out[k.toLowerCase()] = v
      }
      return out
    })

    return Response.json({ golden_id: goldenId, members: items, count: items.length })
  } catch (e) {
    console.error(new Date().toISOString(), "[members]", e)
    return Response.json(
      { error: e instanceof Error ? e.message : "Query failed", members: [] },
      { status: 500 }
    )
  }
}
