"use client"

import { useState, useCallback } from "react"
import { useQuery } from "@tanstack/react-query"
import { KpiCard } from "@/components/kpi-card"
import { HBarChart, type HBarItem } from "@/components/h-bar-chart"

const PAGE_SIZE = 25

interface GoldenRecord {
  golden_id: number
  row_id: number
  first_name_clean?: string
  last_name_clean?: string
  ssn?: string
  ssn_last4?: string
  dob_clean?: string
  address_zip?: string
  quality_score?: number
  cluster_size: number
  source_systems?: string
  [key: string]: unknown
}

interface MatchStats {
  total_pairs: number
  routing: { AUTO_MERGE: number; MANUAL_REVIEW: number; AUTO_REJECT: number }
  rules: { rule_name: string; display_name: string; count: number; pct: number }[]
}

interface Summary {
  recipients: { source_records: number; golden_records: number; merged_entities: number; pending_review: number }
}

export default function RecipientsMatchingPage() {
  const [page, setPage] = useState(0)
  const [search, setSearch] = useState("")
  const [searchInput, setSearchInput] = useState("")
  const [clusterFilter, setClusterFilter] = useState(1)
  const [members, setMembers] = useState<Record<string, unknown>[] | null>(null)
  const [membersLoading, setMembersLoading] = useState(false)
  const [expandedIdx, setExpandedIdx] = useState<number | null>(null)

  const handleExpand = useCallback(async (i: number, goldenId: number) => {
    if (expandedIdx === i) { setExpandedIdx(null); setMembers(null); return }
    setExpandedIdx(i)
    setMembers(null)
    setMembersLoading(true)
    try {
      const res = await fetch(`/api/v1/mdm/recipients/golden-records/${goldenId}/members`)
      const data = await res.json()
      setMembers(data.members ?? [])
    } catch { setMembers([]) }
    finally { setMembersLoading(false) }
  }, [expandedIdx])

  const { data: summary } = useQuery<Summary>({
    queryKey: ["mdm", "summary"],
    queryFn: () => fetch("/api/v1/mdm/summary").then(r => r.json()),
    staleTime: 30000,
  })

  const { data: stats } = useQuery<MatchStats>({
    queryKey: ["mdm", "match-stats", "recipients"],
    queryFn: () => fetch("/api/v1/mdm/recipients/match-stats").then(r => r.json()),
    staleTime: 30000,
  })

  const { data: goldenData, isLoading } = useQuery<{ items: GoldenRecord[]; total: number }>({
    queryKey: ["mdm", "golden", "recipients", page, search, clusterFilter],
    queryFn: () => {
      const p = new URLSearchParams({ limit: String(PAGE_SIZE), offset: String(page * PAGE_SIZE), min_cluster_size: String(clusterFilter) })
      if (search) p.set("search", search)
      return fetch(`/api/v1/mdm/recipients/golden-records?${p}`).then(r => r.json())
    },
    staleTime: 30000,
  })

  const recip = summary?.recipients
  const rules = stats?.rules ?? []
  const barItems: HBarItem[] = rules.map((r, i) => ({
    key: r.rule_name,
    label: `${r.display_name || r.rule_name} (${r.pct}%)`,
    value: r.count,
    color: ["#059669", "#10B981", "#6EE7B7", "#93C5FD", "#3B82F6", "#7C3AED"][i % 6],
  }))

  const handleSearch = () => { setSearch(searchInput); setPage(0) }
  const totalPages = Math.max(1, Math.ceil((goldenData?.total ?? 0) / PAGE_SIZE))

  return (
    <div>
      <div className="mb-4">
        <h1 className="text-xl font-bold">Recipients Matching</h1>
        <p className="text-sm text-muted-foreground">Recipient entity resolution — Golden records from PATIENTS</p>
      </div>

      <div className="grid grid-cols-3 gap-3 mb-5">
        <KpiCard label="Total Source Records" value={recip?.source_records?.toLocaleString() ?? "—"} sub="ALL_RECIPIENTS_CLEAN" />
        <KpiCard label="Golden Records" value={recip?.golden_records?.toLocaleString() ?? "—"} sub={`${recip?.merged_entities?.toLocaleString() ?? 0} merged entities`} variant="accent" />
        <KpiCard label="Pending Review" value={recip?.pending_review?.toLocaleString() ?? "0"} sub="manual review queue" variant={recip?.pending_review ? "warning" : "success"} />
      </div>

      {barItems.length > 0 && (
        <div className="rounded-lg border bg-card mb-5">
          <div className="px-4 py-3 border-b text-sm font-semibold">Match Distribution by Tier</div>
          <div className="p-4">
            <HBarChart items={barItems} height={barItems.length * 44 + 16} />
          </div>
        </div>
      )}

      <div className="flex gap-3 items-center flex-wrap mb-4">
        <input
          value={searchInput}
          onChange={e => setSearchInput(e.target.value)}
          onKeyDown={e => e.key === "Enter" && handleSearch()}
          placeholder="Search name, SSN, ZIP..."
          className="px-3 py-2 text-xs border rounded-md bg-background w-60"
        />
        <button onClick={handleSearch} className="px-3 py-2 text-xs border rounded-md hover:bg-accent">Search</button>
        <select
          value={clusterFilter}
          onChange={e => { setClusterFilter(Number(e.target.value)); setPage(0) }}
          className="px-3 py-2 text-xs border rounded-md bg-background"
        >
          <option value={1}>All records</option>
          <option value={2}>Merged only (2+)</option>
          <option value={3}>Clusters 3+</option>
        </select>
      </div>

      <div className="rounded-lg border bg-card">
        <div className="px-4 py-3 border-b flex justify-between items-center">
          <span className="text-sm font-semibold">Golden Records — Recipient Entities</span>
          <span className="text-[11px] text-muted-foreground">{goldenData?.total?.toLocaleString() ?? 0} total</span>
        </div>
        {isLoading ? (
          <div className="p-8 text-center text-sm text-muted-foreground">Loading...</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b bg-muted/50">
                  <th className="px-3 py-2 text-left font-medium">First Name</th>
                  <th className="px-3 py-2 text-left font-medium">Last Name</th>
                  <th className="px-3 py-2 text-left font-medium">DOB</th>
                  <th className="px-3 py-2 text-left font-medium">SSN</th>
                  <th className="px-3 py-2 text-left font-medium">ZIP</th>
                  <th className="px-3 py-2 text-left font-medium">Matched</th>
                  <th className="px-3 py-2 text-left font-medium">Quality</th>
                </tr>
              </thead>
              <tbody>
                {(goldenData?.items ?? []).map((r, i) => (
                  <>
                  <tr key={i} className="border-b hover:bg-muted/30 cursor-pointer" onClick={() => r.cluster_size > 1 && handleExpand(i, r.golden_id)}>
                    <td className="px-3 py-2 font-semibold">{r.first_name_clean || "—"}</td>
                    <td className="px-3 py-2 font-semibold">{r.last_name_clean || "—"}</td>
                    <td className="px-3 py-2 font-mono text-[10px]">{r.dob_clean || "—"}</td>
                    <td className="px-3 py-2 font-mono">{r.ssn || "—"}</td>
                    <td className="px-3 py-2 font-mono">{r.address_zip || "—"}</td>
                    <td className="px-3 py-2">
                      <span className={`text-[10px] font-bold px-2 py-0.5 rounded ${
                        r.cluster_size > 1 ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-900 dark:text-emerald-300" : "bg-muted text-muted-foreground"
                      }`}>{r.cluster_size} {r.cluster_size > 1 ? "records" : "record"}</span>
                    </td>
                    <td className={`px-3 py-2 font-semibold ${
                      (r.quality_score ?? 0) >= 90 ? "text-emerald-600" : (r.quality_score ?? 0) >= 70 ? "text-amber-600" : "text-red-600"
                    }`}>{r.quality_score ?? "—"}</td>
                  </tr>
                  {expandedIdx === i && (
                    <tr key={`${i}-detail`} className="bg-muted/10">
                      <td colSpan={7} className="px-4 py-3">
                        {membersLoading ? (
                          <div className="text-xs text-muted-foreground py-2">Loading member records...</div>
                        ) : members && members.length > 0 ? (
                          <div>
                            <div className="text-[11px] font-semibold mb-2 text-foreground">{members.length} source records rolled up into this golden entity:</div>
                            <table className="w-full text-[10px] border rounded">
                              <thead>
                                <tr className="border-b bg-muted/50">
                                  <th className="px-2 py-1.5 text-left">ROW_ID</th>
                                  <th className="px-2 py-1.5 text-left">First Name</th>
                                  <th className="px-2 py-1.5 text-left">Last Name</th>
                                  <th className="px-2 py-1.5 text-left">DOB</th>
                                  <th className="px-2 py-1.5 text-left">SSN</th>
                                  <th className="px-2 py-1.5 text-left">Address</th>
                                  <th className="px-2 py-1.5 text-left">Source</th>
                                </tr>
                              </thead>
                              <tbody>
                                {members.map((m: Record<string, unknown>, mi: number) => (
                                  <tr key={mi} className="border-b last:border-0">
                                    <td className="px-2 py-1.5 font-mono">{String(m.row_id ?? "—")}</td>
                                    <td className="px-2 py-1.5">{String(m.first_name_clean ?? "—")}</td>
                                    <td className="px-2 py-1.5">{String(m.last_name_clean ?? "—")}</td>
                                    <td className="px-2 py-1.5 font-mono">{String(m.dob_clean ?? "—")}</td>
                                    <td className="px-2 py-1.5 font-mono">{String(m.ssn ?? "—")}</td>
                                    <td className="px-2 py-1.5 max-w-[200px] truncate">{String(m.address_clean ?? "—")}</td>
                                    <td className="px-2 py-1.5">{String(m._source_system ?? "—")}</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </div>
                        ) : (
                          <div className="text-xs text-muted-foreground py-2">No member details available</div>
                        )}
                      </td>
                    </tr>
                  )}
                  </>
                ))}
                {(goldenData?.items ?? []).length === 0 && (
                  <tr><td colSpan={7} className="px-3 py-8 text-center text-muted-foreground">No records found</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
        <div className="px-4 py-3 border-t flex justify-between items-center text-xs">
          <span className="text-muted-foreground">Page {page + 1} of {totalPages}</span>
          <div className="flex gap-2">
            <button onClick={() => setPage(p => Math.max(0, p - 1))} disabled={page === 0} className="px-3 py-1 border rounded disabled:opacity-40">Prev</button>
            <button onClick={() => setPage(p => p + 1)} disabled={(page + 1) * PAGE_SIZE >= (goldenData?.total ?? 0)} className="px-3 py-1 border rounded disabled:opacity-40">Next</button>
          </div>
        </div>
      </div>
    </div>
  )
}
