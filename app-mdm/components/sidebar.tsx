"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import { ThemeToggle } from "@/components/theme-toggle"

const NAV_ITEMS = [
  { section: "Providers", items: [
    { href: "/providers/matching", label: "Matching Overview" },
    { href: "/providers/alerts", label: "Alerts & Review" },
    { href: "/providers/logic", label: "Matching Logic" },
  ]},
  { section: "Recipients", items: [
    { href: "/recipients/matching", label: "Matching Overview" },
    { href: "/recipients/alerts", label: "Alerts & Review" },
    { href: "/recipients/logic", label: "Matching Logic" },
  ]},
]

export function Sidebar() {
  const pathname = usePathname()

  return (
    <aside className="fixed top-0 left-0 h-full w-56 bg-[var(--brand-nav-bg)] text-[var(--brand-nav-fg)] flex flex-col z-40">
      <div className="px-4 py-5 border-b border-white/10">
        <div className="text-sm font-bold tracking-tight">Master Data Management</div>
        <div className="text-[10px] text-white/50 mt-0.5">Matching & Resolution</div>
      </div>
      <nav className="flex-1 overflow-y-auto py-3 px-2">
        {NAV_ITEMS.map(group => (
          <div key={group.section} className="mb-4">
            <div className="px-2 mb-1 text-[10px] font-semibold uppercase tracking-wider text-white/40">
              {group.section}
            </div>
            {group.items.map(item => {
              const active = pathname === item.href
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={`block px-3 py-2 rounded-md text-xs font-medium transition-colors ${
                    active
                      ? "bg-white/15 text-white"
                      : "text-white/70 hover:bg-white/10 hover:text-white"
                  }`}
                >
                  {item.label}
                </Link>
              )
            })}
          </div>
        ))}
      </nav>
      <div className="px-4 py-3 border-t border-white/10 flex items-center justify-end">
        <ThemeToggle />
      </div>
    </aside>
  )
}
