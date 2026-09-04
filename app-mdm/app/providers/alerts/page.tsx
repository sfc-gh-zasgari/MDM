"use client"

import { useState, useCallback } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { KpiCard } from "@/components/kpi-card"

export default function ProviderAlertsPage() {
  const [expandedIdx, setExpandedIdx] = useState<number | null>(null)
  const [deciding, setDeciding] = useState<string | null>(null)
  const queryClient = useQueryClient()

  const { data, isLoading } = useQuery<{ items: Record<string, unknown>[]; total: number }>({
    queryKey: ["mdm", "alerts", "providers"],
    queryFn: () => fetch("/api/v1/mdm/providers/review-queue?limit=50&offset=0").then(r => r.json()),
    staleTime: 30000,
  })

  const items = data?.items ?? []
  const total = data?.total ?? 0

  const handleExpand = useCallback((i: number) => {
    setExpandedIdx(expandedIdx === i ? null : i)
  }, [expandedIdx])

  const handleDecision = async (rowA: number, rowB: number, decision: "APPROVE" | "REJECT") => {
    const key = `${rowA}-${rowB}`
    setDeciding(key)
    try {
      const res = await fetch("/api/v1/mdm/providers/review-queue/decide", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ row_a: rowA, row_b: rowB, decision }),
      })
      if (res.ok) {
        setExpandedIdx(null)
        queryClient.invalidateQueries({ queryKey: ["mdm", "alerts", "providers"] })
        queryClient.invalidateQueries({ queryKey: ["mdm", "match-stats", "providers"] })
        queryClient.invalidateQueries({ queryKey: ["mdm", "summary"] })
      }
    } finally {
      setDeciding(null)
    }
  }

  return (
    <div>
      <div className="mb-4">
        <h1 className="text-xl font-bold">Provider Alerts</h1>
        <p className="text-sm text-muted-foreground">Manual review queue — pairs requiring steward decision</p>
      </div>

      <div className="grid grid-cols-3 gap-3 mb-5">
        <KpiCard label="Pending Review" value={total.toLocaleString()} sub="pairs in queue" variant={total > 0 ? "warning" : "success"} />
        <KpiCard label="Status" value={total === 0 ? "All Clear" : "Action Needed"} sub={total === 0 ? "pipeline resolved all pairs" : "steward decisions required"} variant={total === 0 ? "success" : "warning"} />
        <KpiCard label="Thresholds" value="ML Tier" sub="Auto-merge >= 80% · Review >= 65% · Reject < 65%" />
      </div>

      <div className="rounded-lg border bg-card">
        <div className="px-4 py-3 border-b flex justify-between items-center">
          <span className="text-sm font-semibold">Review Queue</span>
          <span className="text-[11px] text-muted-foreground">{total.toLocaleString()} pairs</span>
        </div>
        {isLoading ? (
          <div className="p-8 text-center text-sm text-muted-foreground">Loading...</div>
        ) : items.length === 0 ? (
          <div className="p-12 text-center">
            <div className="text-3xl mb-3 text-muted-foreground">No alerts</div>
            <div className="text-sm text-muted-foreground max-w-md mx-auto leading-relaxed">
              The three-tier pipeline (Deterministic Rules, ML Classification, LLM Reasoning) resolved all provider pairs automatically. No pairs require manual steward review.
            </div>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b bg-muted/50">
                  <th className="px-3 py-2 text-left font-medium">Name A</th>
                  <th className="px-3 py-2 text-left font-medium">Name B</th>
                  <th className="px-3 py-2 text-left font-medium">Score</th>
                  <th className="px-3 py-2 text-left font-medium">Match Type</th>
                  <th className="px-3 py-2 text-left font-medium">Details</th>
                </tr>
              </thead>
              <tbody>
                {items.map((r, i) => {
                  const rowA = Number(r.row_a)
                  const rowB = Number(r.row_b)
                  const pairKey = `${rowA}-${rowB}`
                  return (
                  <>
                  <tr key={i} className="border-b hover:bg-muted/30 cursor-pointer" onClick={() => handleExpand(i)}>
                    <td className="px-3 py-2 font-semibold">{String(r.name_a ?? "—")}</td>
                    <td className="px-3 py-2 font-semibold">{String(r.name_b ?? "—")}</td>
                    <td className="px-3 py-2">
                      <span className={`font-bold ${
                        (Number(r.hybrid_score) || 0) >= 0.6 ? "text-amber-600" : "text-red-500"
                      }`}>{((Number(r.hybrid_score) || 0) * 100).toFixed(1)}%</span>
                    </td>
                    <td className="px-3 py-2 text-[10px]">{String(r.match_type_display ?? r.match_type ?? "—")}</td>
                    <td className="px-3 py-2 text-blue-600 font-medium text-[10px]">{expandedIdx === i ? "▼ Collapse" : "▶ Expand"}</td>
                  </tr>
                  {expandedIdx === i && (
                    <tr key={`${i}-detail`} className="bg-muted/10">
                      <td colSpan={5} className="px-4 py-3">
                        <div className="grid grid-cols-2 gap-4 text-[11px]">
                          <div className="space-y-2">
                            <div className="font-semibold text-xs border-b pb-1 mb-1">Record A</div>
                            <div><span className="text-muted-foreground">Name:</span> {String(r.name_a ?? "—")}</div>
                            <div><span className="text-muted-foreground">NPI:</span> {String(r.npi_a ?? "—")}</div>
                            <div><span className="text-muted-foreground">Address:</span> {String(r.addr_a ?? "—")}</div>
                            <div><span className="text-muted-foreground">ZIP:</span> {String(r.zip_a ?? "—")}</div>
                            <div><span className="text-muted-foreground">Type:</span> {String(r.type_a ?? "—")}</div>
                            <div><span className="text-muted-foreground">Phone:</span> {String(r.phone_a ?? "—")}</div>
                            <div><span className="text-muted-foreground">Source:</span> {String(r.source_a ?? "—")}</div>
                          </div>
                          <div className="space-y-2">
                            <div className="font-semibold text-xs border-b pb-1 mb-1">Record B</div>
                            <div><span className="text-muted-foreground">Name:</span> {String(r.name_b ?? "—")}</div>
                            <div><span className="text-muted-foreground">NPI:</span> {String(r.npi_b ?? "—")}</div>
                            <div><span className="text-muted-foreground">Address:</span> {String(r.addr_b ?? "—")}</div>
                            <div><span className="text-muted-foreground">ZIP:</span> {String(r.zip_b ?? "—")}</div>
                            <div><span className="text-muted-foreground">Type:</span> {String(r.type_b ?? "—")}</div>
                            <div><span className="text-muted-foreground">Phone:</span> {String(r.phone_b ?? "—")}</div>
                            <div><span className="text-muted-foreground">Source:</span> {String(r.source_b ?? "—")}</div>
                          </div>
                        </div>
                        <div className="mt-3 pt-2 border-t flex items-center justify-between">
                          <span className="text-[10px] text-muted-foreground">
                            ML confidence: {((Number(r.hybrid_score) || 0) * 100).toFixed(2)}% · Row IDs: {rowA} - {rowB}
                          </span>
                          <div className="flex gap-2">
                            <button
                              onClick={(e) => { e.stopPropagation(); handleDecision(rowA, rowB, "APPROVE") }}
                              disabled={deciding === pairKey}
                              className="px-3 py-1.5 text-xs font-semibold rounded bg-emerald-600 text-white hover:bg-emerald-700 disabled:opacity-50"
                            >
                              {deciding === pairKey ? "..." : "Approve (Merge)"}
                            </button>
                            <button
                              onClick={(e) => { e.stopPropagation(); handleDecision(rowA, rowB, "REJECT") }}
                              disabled={deciding === pairKey}
                              className="px-3 py-1.5 text-xs font-semibold rounded bg-red-600 text-white hover:bg-red-700 disabled:opacity-50"
                            >
                              {deciding === pairKey ? "..." : "Reject (Separate)"}
                            </button>
                          </div>
                        </div>
                      </td>
                    </tr>
                  )}
                  </>
                )})}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
