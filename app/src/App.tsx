import { Routes, Route, Navigate } from 'react-router-dom'
import { NetworkBar } from './components/NetworkBar'
import { NetworkLeaves } from './components/LeafField'
import { BottomNav } from './components/BottomNav'
import { DraftProvider } from './lib/draft'
import { Launch } from './pages/Launch'
import { Board } from './pages/Board'
import { Token } from './pages/Token'
import { TokenPage } from './pages/TokenPage'
import { Rewards } from './pages/Rewards'
import { Docs } from './pages/Docs'
import { About } from './pages/About'

export default function App() {
  return (
    <DraftProvider>
      <div className="relative min-h-dvh bg-ink-950">
        {/* Behind everything, Robinhood only, unmounted elsewhere. See LeafField for why canvas. */}
        <NetworkLeaves />

        <header className="sticky top-0 z-40">
          <NetworkBar />
        </header>

        {/* pb clears the fixed bottom nav plus the iOS home indicator. */}
        <main className="mx-auto max-w-2xl px-4 pb-32 pt-5">
          <Routes>
            <Route path="/" element={<Launch />} />
            <Route path="/board" element={<Board />} />
        <Route path="/t/:address" element={<Token />} />
            <Route path="/preview" element={<TokenPage />} />
            <Route path="/rewards" element={<Rewards />} />
            <Route path="/docs" element={<Docs />} />
            <Route path="/about" element={<About />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>

        <BottomNav />
      </div>
    </DraftProvider>
  )
}
