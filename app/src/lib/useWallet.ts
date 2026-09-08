/**
 * Wallet state as React sees it.
 *
 * Listens for `accountsChanged` and `chainChanged` rather than reading once on mount. A user who
 * switches network in their wallet while looking at a launch form must not be left with a button
 * that says "Launch" and a wallet pointed at mainnet — that is precisely the case where an
 * enabled-looking control does the wrong thing.
 */
import { useCallback, useEffect, useState } from 'react'
import type { Address } from 'viem'
import { activeNetwork } from './activeNetwork'
import {
  connect as doConnect,
  currentAccounts,
  currentChainId,
  getProvider,
  hasWallet,
  switchToActiveChain,
  walletErrorMessage,
} from './wallet'

export type WalletState = {
  installed: boolean
  account: Address | null
  chainId: number | null
  onRightChain: boolean
  connecting: boolean
  error: string | null
  connect: () => Promise<void>
  switchChain: () => Promise<void>
}

export function useWallet(): WalletState {
  const installed = hasWallet()
  const [account, setAccount] = useState<Address | null>(null)
  const [chainId, setChainId] = useState<number | null>(null)
  const [connecting, setConnecting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Restore an already-authorised session without prompting. Prompting on load is how a site
  // trains people to dismiss wallet popups without reading them.
  useEffect(() => {
    let live = true
    void (async () => {
      const [accts, id] = await Promise.all([currentAccounts(), currentChainId()])
      if (!live) return
      setAccount(accts[0] ?? null)
      setChainId(id)
    })()
    return () => {
      live = false
    }
  }, [])

  useEffect(() => {
    const p = getProvider()
    if (!p?.on) return
    const onAccounts = (...args: unknown[]) => {
      const accts = args[0] as Address[] | undefined
      setAccount(accts && accts.length > 0 ? accts[0] : null)
    }
    const onChain = (...args: unknown[]) => {
      const hex = args[0] as string | undefined
      setChainId(hex ? Number.parseInt(hex, 16) : null)
    }
    p.on('accountsChanged', onAccounts)
    p.on('chainChanged', onChain)
    return () => {
      p.removeListener?.('accountsChanged', onAccounts)
      p.removeListener?.('chainChanged', onChain)
    }
  }, [])

  const connect = useCallback(async () => {
    setError(null)
    setConnecting(true)
    try {
      const accts = await doConnect()
      setAccount(accts[0] ?? null)
      setChainId(await currentChainId())
    } catch (e) {
      setError(walletErrorMessage(e))
    } finally {
      setConnecting(false)
    }
  }, [])

  const switchChain = useCallback(async () => {
    setError(null)
    try {
      await switchToActiveChain()
      setChainId(await currentChainId())
    } catch (e) {
      setError(walletErrorMessage(e))
    }
  }, [])

  return {
    installed,
    account,
    chainId,
    onRightChain: chainId === activeNetwork().chain.id,
    connecting,
    error,
    connect,
    switchChain,
  }
}
