import { querySnowflake } from "@/lib/snowflake"
import { NextRequest } from "next/server"

export const dynamic = "force-dynamic"

const TABLES: Record<string, string> = {
  providers: "MDM.MATCHING.PROVIDER_MATCH_RESULTS",
  recipients: "MDM.MATCHING.RECIPIENT_MATCH_RESULTS",
}

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ entityType: string }> }
) {
  const { entityType } = await params
  const table = TABLES[entityType]
  if (!table) {
    return Response.json({ error: "Invalid entity type" }, { status: 400 })
  }

  const body = await request.json()
  const { row_a, row_b, decision, notes } = body

  if (!row_a || !row_b || !decision) {
    return Response.json({ error: "row_a, row_b, and decision are required" }, { status: 400 })
  }

  if (!["APPROVE", "REJECT"].includes(decision)) {
    return Response.json({ error: "decision must be APPROVE or REJECT" }, { status: 400 })
  }

  try {
    // Get the pair's details for audit
    const [pair] = await querySnowflake(`
      SELECT MATCH_TYPE, HYBRID_SCORE
      FROM ${table}
      WHERE ROW_A = ${row_a} AND ROW_B = ${row_b} AND ROUTING = 'MANUAL_REVIEW'
    `)

    if (!pair) {
      return Response.json({ error: "Pair not found in review queue" }, { status: 404 })
    }

    // Log the decision
    const safeNotes = (notes || "").replace(/'/g, "''")
    await querySnowflake(`
      INSERT INTO MDM.MATCHING.STEWARD_DECISIONS (ROW_A, ROW_B, ENTITY_TYPE, MATCH_TYPE, HYBRID_SCORE, DECISION, DECIDED_BY, NOTES)
      VALUES (${row_a}, ${row_b}, '${entityType}', '${pair.MATCH_TYPE}', ${pair.HYBRID_SCORE}, '${decision}', CURRENT_USER(), '${safeNotes}')
    `)

    // Apply the decision
    if (decision === "APPROVE") {
      await querySnowflake(`
        UPDATE ${table}
        SET ROUTING = 'AUTO_MERGE'
        WHERE ROW_A = ${row_a} AND ROW_B = ${row_b} AND ROUTING = 'MANUAL_REVIEW'
      `)
    } else {
      await querySnowflake(`
        DELETE FROM ${table}
        WHERE ROW_A = ${row_a} AND ROW_B = ${row_b} AND ROUTING = 'MANUAL_REVIEW'
      `)
    }

    return Response.json({ success: true, decision, row_a, row_b })
  } catch (e) {
    console.error(new Date().toISOString(), "[review-decide]", e)
    return Response.json(
      { error: e instanceof Error ? e.message : "Decision failed" },
      { status: 500 }
    )
  }
}
