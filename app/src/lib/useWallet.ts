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
  disconnect as doDisconnect,
  getProvider,
  hasInjectedWallet,
  isWalletConnectSession,
  restoreWalletConnect,
  walletConnectConfigured,
  switchToActiveChain,
  walletErrorMessage,
  type Transport,
} from './wallet'

export type WalletState = {
  /** Can the user connect AT ALL - by any route, not just an extension. */
  canConnect: boolean
  /** Is there a browser extension? Drives whether a choice is worth offering. */
  hasInjected: boolean
  /** Is WalletConnect available in this deployment? False when no projectId is set. */
  hasWalletConnect: boolean
  /** Is the LIVE session a WalletConnect one? Only then is disconnecting meaningful. */
  isWalletConnect: boolean
  account: Address | null
  chainId: number | null
  onRightChain: boolean
  connecting: boolean
  error: string | null
  connect: (transport?: Transport) => Promise<void>
  disconnect: () => Promise<void>
  switchChain: () => Promise<void>
}

export function useWallet(): WalletState {
  const hasInjected = hasInjectedWallet()
  const hasWalletConnect = walletConnectConfigured()
  const [account, setAccount] = useState<Address | null>(null)
  const [chainId, setChainId] = useState<number | null>(null)
  const [connecting, setConnecting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Bumped after connect/disconnect so the listener effect re-subscribes: the provider OBJECT
  // changes when a WalletConnect session starts, and listeners bound to the old one are deaf.
  const [providerEpoch, setProviderEpoch] = useState(0)

  // Restore an already-authorised session without prompting. Prompting on load is how a site
  // trains people to dismiss wallet popups without reading them.
  //
  // WalletConnect is restored FIRST and awaited, because `currentAccounts()` reads through
  // `getProvider()` - if the WC session has not been re-attached by then, a returning mobile user
  // reads as disconnected and is asked to scan a QR code they already scanned.
  useEffect(() => {
    let live = true
    void (async () => {
      const wcAccounts = await restoreWalletConnect()
      if (!live) return
      if (wcAccounts.length > 0) setProviderEpoch((n) => n + 1)

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
    // WalletConnect emits `disconnect` when the session ends from the WALLET side - the user
    // hitting disconnect on their phone. Without this the site keeps showing an address that can
    // no longer sign anything, which is the worst of both states.
    const onDisconnect = () => {
      setAccount(null)
      setChainId(null)
    }
    p.on('accountsChanged', onAccounts)
    p.on('chainChanged', onChain)
    p.on('disconnect', onDisconnect)
    return () => {
      p.removeListener?.('accountsChanged', onAccounts)
      p.removeListener?.('chainChanged', onChain)
      p.removeListener?.('disconnect', onDisconnect)
    }
  }, [providerEpoch])

  const connect = useCallback(async (transport: Transport = 'auto') => {
    setError(null)
    setConnecting(true)
    try {
      const accts = await doConnect(transport)
      // Re-subscribe: on the WalletConnect path the provider we listen to did not exist a moment
      // ago, so the effect above must run again against the new object.
      setProviderEpoch((n) => n + 1)
      setAccount(accts[0] ?? null)
      setChainId(await currentChainId())
    } catch (e) {
      setError(walletErrorMessage(e))
    } finally {
      setConnecting(false)
    }
  }, [])

  const disconnect = useCallback(async () => {
    setError(null)
    await doDisconnect()
    setAccount(null)
    setChainId(null)
    setProviderEpoch((n) => n + 1)
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
    canConnect: hasInjected || hasWalletConnect,
    isWalletConnect: isWalletConnectSession(),
    hasInjected,
    hasWalletConnect,
    account,
    chainId,
    onRightChain: chainId === activeNetwork().chain.id,
    connecting,
    error,
    connect,
    disconnect,
    switchChain,
  }
}
