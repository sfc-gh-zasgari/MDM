import type { Metadata } from "next"
import type React from "react"
import { ThemeProvider } from "@/components/theme-provider"
import { QueryProvider } from "@/components/query-provider"
import { Sidebar } from "@/components/sidebar"
import { APP_TITLE, LOGO_SRC } from "@/lib/constants"
import "./globals.css"

export const metadata: Metadata = {
  title: APP_TITLE,
  description: "Master Data Management — Provider & Recipient Entity Resolution",
  icons: { icon: LOGO_SRC },
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">
        <ThemeProvider>
          <QueryProvider>
            <Sidebar />
            <main className="ml-56 min-h-screen p-6">
              {children}
            </main>
          </QueryProvider>
        </ThemeProvider>
      </body>
    </html>
  )
}
