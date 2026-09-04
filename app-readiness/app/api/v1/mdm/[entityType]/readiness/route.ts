import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

export async function GET(
  _request: NextRequest,
  { params }: { params: Promise<{ entityType: string }> }
) {
  const { entityType } = await params
  if (!["providers", "recipients"].includes(entityType)) {
    return Response.json({ error: "Invalid entity type" }, { status: 400 })
  }

  try {
    const rows = await querySnowflake(`
      SELECT COLUMN_NAME, COMPLETENESS, UNIQUENESS, VALIDITY, CONSISTENCY,
             ROUND((COMPLETENESS + UNIQUENESS + VALIDITY + CONSISTENCY) / 4.0, 0) AS SCORE
      FROM   MDM.MASTER.DATA_READINESS_STATS
      WHERE  ENTITY_TYPE = '${entityType}'
      ORDER  BY COMPLETENESS DESC
    `)

    const meta = await querySnowflake(`
      SELECT SOURCE_TABLE, TOTAL_ROWS
      FROM   MDM.MASTER.DATA_READINESS_STATS
      WHERE  ENTITY_TYPE = '${entityType}'
      LIMIT 1
    `)

    const totalRows = meta.length > 0 ? Number(meta[0].TOTAL_ROWS) : 0
    const sourceTable = meta.length > 0 ? String(meta[0].SOURCE_TABLE) : ""

    const columns = rows.map((r: Record<string, unknown>) => ({
      column: String(r.COLUMN_NAME),
      completeness: Math.round(Number(r.COMPLETENESS)),
      uniqueness: Math.round(Number(r.UNIQUENESS)),
      validity: Math.round(Number(r.VALIDITY)),
      consistency: Math.round(Number(r.CONSISTENCY)),
      score: Math.round(Number(r.SCORE)),
    }))

    const avgCompleteness = columns.length > 0
      ? Math.round(columns.reduce((s, c) => s + c.completeness, 0) / columns.length)
      : 0
    const overallScore = columns.length > 0
      ? Math.round(columns.reduce((s, c) => s + c.score, 0) / columns.length)
      : 0

    return Response.json({
      table: sourceTable,
      total_rows: totalRows,
      overall_score: overallScore,
      avg_completeness: avgCompleteness,
      columns_assessed: columns.length,
      columns,
    })
  } catch (e) {
    console.error(new Date().toISOString(), "[readiness]", e)
    return Response.json(
      { error: e instanceof Error ? e.message : "Query failed", columns: [] },
      { status: 500 }
    )
  }
}
