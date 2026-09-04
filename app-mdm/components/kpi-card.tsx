interface KpiCardProps {
  label: string
  value: string | number
  sub?: string
  variant?: "default" | "critical" | "warning" | "success" | "accent"
}

const VARIANT_STYLES: Record<string, string> = {
  default: "border-border",
  critical: "border-red-300 dark:border-red-800",
  warning: "border-amber-300 dark:border-amber-800",
  success: "border-emerald-300 dark:border-emerald-800",
  accent: "border-blue-300 dark:border-blue-800",
}

const VALUE_COLORS: Record<string, string> = {
  default: "text-foreground",
  critical: "text-red-600 dark:text-red-400",
  warning: "text-amber-600 dark:text-amber-400",
  success: "text-emerald-600 dark:text-emerald-400",
  accent: "text-blue-600 dark:text-blue-400",
}

export function KpiCard({ label, value, sub, variant = "default" }: KpiCardProps) {
  return (
    <div className={`rounded-lg border bg-card p-4 ${VARIANT_STYLES[variant]}`}>
      <div className="text-[11px] font-medium text-muted-foreground uppercase tracking-wide">{label}</div>
      <div className={`text-2xl font-bold mt-1 ${VALUE_COLORS[variant]}`}>{value}</div>
      {sub && <div className="text-[11px] text-muted-foreground mt-1">{sub}</div>}
    </div>
  )
}
