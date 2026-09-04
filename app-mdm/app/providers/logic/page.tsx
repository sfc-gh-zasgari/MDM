"use client"

import { useQuery } from "@tanstack/react-query"
import { KpiCard } from "@/components/kpi-card"
import { HBarChart, type HBarItem } from "@/components/h-bar-chart"

interface MatchStats {
  total_pairs: number
  routing: { AUTO_MERGE: number; MANUAL_REVIEW: number; AUTO_REJECT: number }
  rules: { rule_name: string; display_name: string; count: number; pct: number }[]
}

const RULE_COLORS = ["#2563EB", "#7C3AED", "#059669", "#D97706", "#DC2626", "#64748B"]

export default function ProviderLogicPage() {
  const { data, isLoading } = useQuery<MatchStats>({
    queryKey: ["mdm", "match-stats", "providers"],
    queryFn: () => fetch("/api/v1/mdm/providers/match-stats").then(r => r.json()),
    staleTime: 30000,
  })

  const rules = data?.rules ?? []
  const routing = data?.routing

  const barItems: HBarItem[] = rules.map((r, i) => ({
    key: r.rule_name,
    label: r.display_name || r.rule_name,
    value: r.count,
    color: RULE_COLORS[i % RULE_COLORS.length],
  }))

  return (
    <div>
      <div className="mb-4">
        <h1 className="text-xl font-bold">Provider Matching Logic</h1>
        <p className="text-sm text-muted-foreground">Three-tier architecture: Deterministic Rules → ML → LLM</p>
      </div>

      {isLoading ? (
        <div className="p-8 text-center text-sm text-muted-foreground">Loading...</div>
      ) : (
        <>
          <div className="grid grid-cols-4 gap-3 mb-5">
            <KpiCard label="Total Pairs Evaluated" value={data?.total_pairs?.toLocaleString() ?? "0"} variant="accent" />
            <KpiCard label="Auto-Merged" value={routing?.AUTO_MERGE?.toLocaleString() ?? "0"} sub="high confidence" variant="success" />
            <KpiCard label="Manual Review" value={routing?.MANUAL_REVIEW?.toLocaleString() ?? "0"} sub="steward needed" variant="warning" />
            <KpiCard label="Auto-Rejected" value={routing?.AUTO_REJECT?.toLocaleString() ?? "0"} sub="low confidence" />
          </div>

          {barItems.length > 0 && (
            <div className="rounded-lg border bg-card mb-5">
              <div className="px-4 py-3 border-b text-sm font-semibold">Pairs Matched per Rule</div>
              <div className="p-4">
                <HBarChart items={barItems} height={rules.length * 48 + 24} />
              </div>
            </div>
          )}

          <div className="rounded-lg border bg-card mb-5">
            <div className="px-4 py-3 border-b flex justify-between items-center">
              <span className="text-sm font-semibold">Rule Definitions</span>
              <span className="text-[11px] text-muted-foreground">5 deterministic rules + ML + LLM</span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b bg-muted/50">
                    <th className="px-3 py-2 text-left font-medium">Rule</th>
                    <th className="px-3 py-2 text-left font-medium">Pairs</th>
                    <th className="px-3 py-2 text-left font-medium">% of Total</th>
                  </tr>
                </thead>
                <tbody>
                  {rules.length === 0 ? (
                    <tr><td colSpan={3} className="px-3 py-8 text-center text-muted-foreground">No matching data yet — run the pipeline first</td></tr>
                  ) : rules.map(r => (
                    <tr key={r.rule_name} className="border-b">
                      <td className="px-3 py-2 font-semibold text-[10px]">{r.display_name || r.rule_name}</td>
                      <td className="px-3 py-2 font-bold font-mono">{r.count.toLocaleString()}</td>
                      <td className="px-3 py-2">
                        <div className="flex items-center gap-2">
                          <div className="w-20 h-2 bg-muted rounded-full overflow-hidden">
                            <div className="h-full bg-blue-600 rounded-full" style={{ width: `${r.pct}%` }} />
                          </div>
                          <span className="text-blue-600 font-semibold">{r.pct}%</span>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="rounded-lg border bg-card">
            <div className="px-4 py-3 border-b text-sm font-semibold">How Matching Works — Three-Tier Architecture</div>
            <div className="p-4 text-xs text-muted-foreground leading-relaxed space-y-3">
              <p><strong className="text-foreground">Tier 1 — Deterministic Rules (SQL, COMPUTE_WH)</strong><br />
              5 universal rules applied to all 374,787 provider records. Uses ROW_ID for deduplication and star topology for NPI groups.</p>
              <ul className="list-disc pl-5 space-y-1">
                <li><strong>T0:</strong> Exact NPI match (confidence 1.00) — ~78K pairs</li>
                <li><strong>T2:</strong> Exact NAME + ADDRESS + ZIP + TYPE (0.95) — ~2.4K pairs</li>
                <li><strong>T3:</strong> JAROWINKLER(name) &ge; 85% + exact ADDR + ZIP + TYPE (0.88) — ~15K pairs</li>
                <li><strong>T4:</strong> JAROWINKLER(secondary name) &ge; 85% + ADDR + ZIP + TYPE (0.88) — ~47 pairs</li>
              </ul>
              <p><strong className="text-foreground">Tier 2 — ML Classification (SNOWFLAKE.ML.CLASSIFICATION, ADOPTIVE_WH)</strong><br />
              For pairs with 50-84% name similarity that Tier 1 could not resolve. 10 numeric features. Threshold: &ge; 0.80 confidence.</p>
              <p><strong className="text-foreground">Tier 3 — LLM Reasoning (SNOWFLAKE.CORTEX.COMPLETE, llama4-maverick)</strong><br />
              For genuinely ambiguous pairs ML scored 0.20-0.80. Returns MATCH/NO_MATCH with reasoning.</p>
              <p><strong className="text-foreground">Routing:</strong> Tier 1 → AUTO_MERGE | ML &ge; 0.80 → AUTO_MERGE | ML 0.20-0.80 → LLM | ML &lt; 0.20 → AUTO_REJECT</p>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
