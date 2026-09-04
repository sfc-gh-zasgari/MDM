"use client"

import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, Cell } from "recharts"

export interface HBarItem {
  key: string
  label: string
  value: number
  color: string
}

interface Props {
  items: HBarItem[]
  height?: number
}

export function HBarChart({ items, height }: Props) {
  const chartHeight = height ?? Math.max(items.length * 42 + 24, 100)

  return (
    <ResponsiveContainer width="100%" height={chartHeight}>
      <BarChart data={items} layout="vertical" margin={{ top: 4, right: 60, bottom: 4, left: 10 }}>
        <XAxis type="number" hide />
        <YAxis
          type="category"
          dataKey="label"
          width={200}
          tick={{ fontSize: 11, fill: "var(--color-muted-foreground)" }}
          axisLine={false}
          tickLine={false}
        />
        <Tooltip
          contentStyle={{ background: "var(--color-card)", border: "1px solid var(--color-border)", borderRadius: 6, fontSize: 12 }}
          formatter={(value: number) => [value.toLocaleString(), "Pairs"]}
        />
        <Bar dataKey="value" radius={[0, 4, 4, 0]} barSize={24} label={{ position: "right", fontSize: 11, fontWeight: 700, fill: "var(--color-muted-foreground)", formatter: (v: number) => v.toLocaleString() }}>
          {items.map((item, i) => (
            <Cell key={i} fill={item.color} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}
