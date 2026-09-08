import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
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
  // The token page is two columns and needs the room; every other page is a single column of
  // fields that reads worse when stretched.
  const wide = useLocation().pathname.startsWith('/t/')

  return (
    <DraftProvider>
      <div className="relative min-h-dvh bg-ink-950">
        {/* Behind everything, Robinhood only, unmounted elsewhere. See LeafField for why canvas. */}
        <NetworkLeaves />

        <header className="sticky top-0 z-40">
          <NetworkBar />
        </header>

        {/* pb clears the fixed bottom nav plus the iOS home indicator. */}
        <main
          className={`mx-auto px-4 pb-32 pt-5 ${
            wide ? 'max-w-5xl' : 'max-w-2xl'
          }`}
        >
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
