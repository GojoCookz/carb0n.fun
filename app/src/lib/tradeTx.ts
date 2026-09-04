/**
 * Buying and selling a launched token.
 *
 * Goes through our own `TradeRouter` rather than Uniswap's UniversalRouter. Two reasons, and the
 * second is the one that matters: the UniversalRouter needs a command stream and Permit2, which
 * is two extra concepts and an extra signature for somebody pressing Buy — and more importantly,
 * a router that pays the pool BEFORE swapping gets silently overcharged by our own hook. The
 * audit measured 8.5x on an identical trade, because `FeeHook` moves ERC-20 out of the singleton
 * during `afterSwap` and `PoolManager._settle` credits `balanceOfSelf() - syncedReserves`.
 * `TradeRouter` swaps first and settles from the delta. See `src/TradeRouter.sol`.
 */
import { parseUnits, type Address, type Hash } from 'viem'
import { sepoliaClient, DEPLOYMENTS } from './chain'
import { ERC20_ABI } from './abi'
import { walletClient } from './wallet'

export const TRADE_ROUTER: Address = '0xdd48D62D1127f12838a5672B457843B81844E62F'

/** Every launch opens with this spacing. Mirrors `TICK_SPACING` in `launchTx.ts`. */
const TICK_SPACING = 60

export const TRADE_ROUTER_ABI = [
  {
    name: 'swap',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      {
        name: 'key',
        type: 'tuple',
        components: [
          { name: 'currency0', type: 'address' },
          { name: 'currency1', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'tickSpacing', type: 'int24' },
          { name: 'hooks', type: 'address' },
        ],
      },
      { name: 'zeroForOne', type: 'bool' },
      { name: 'amountIn', type: 'uint256' },
      { name: 'minAmountOut', type: 'uint256' },
      { name: 'recipient', type: 'address' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
] as const

export type TradePhase =
  | { kind: 'idle' }
  | { kind: 'approving'; hash?: Hash }
  | { kind: 'trading'; hash?: Hash }
  | { kind: 'done'; amountOut: bigint; hash: Hash }
  | { kind: 'error'; message: string }

/**
 * Rebuild the pool key from the two addresses.
 *
 * **v4 sorts currencies by address and the whole key must match EXACTLY** — a single wrong field
 * and the manager reports `PoolNotInitialized` for a pool that plainly exists. `fee` is ZERO on
 * every pool here because the hook charges instead of the pool; passing the trading rate would
 * point at a pool nobody created.
 */
export function poolKeyFor(token: Address, pair: Address) {
  const tokenIsCurrency0 = token.toLowerCase() < pair.toLowerCase()
  return {
    key: {
      currency0: (tokenIsCurrency0 ? token : pair) as Address,
      currency1: (tokenIsCurrency0 ? pair : token) as Address,
      fee: 0,
      tickSpacing: TICK_SPACING,
      hooks: DEPLOYMENTS.sepolia.feeHook as Address,
    },
    /** Spending the PAIR currency — i.e. the direction that buys the launch token. */
    buyIsZeroForOne: !tokenIsCurrency0,
  }
}

/**
 * Approve if needed, then swap.
 *
 * **Slippage is the caller's, expressed in basis points, and it is not optional.** A swap sent
 * with `minAmountOut = 0` is an instruction to accept any price at all, which on a thin pool is
 * an instruction to be sandwiched. The quote is simulated first so the minimum is derived from
 * what the pool would actually pay right now rather than from a guess.
 */
export async function submitTrade(
  opts: {
    token: Address
    pair: Address
    pairDecimals: number
    tokenDecimals: number
    /** True to spend pair currency and receive the launch token. */
    isBuy: boolean
    /** Human amount of whichever currency is being SPENT. */
    amount: number
    /** Tolerated slippage, in basis points. 100 = 1%. */
    slippageBps: number
    account: Address
  },
  onPhase: (p: TradePhase) => void,
): Promise<void> {
  const { key, buyIsZeroForOne } = poolKeyFor(opts.token, opts.pair)
  const zeroForOne = opts.isBuy ? buyIsZeroForOne : !buyIsZeroForOne

  const inToken = opts.isBuy ? opts.pair : opts.token
  const inDecimals = opts.isBuy ? opts.pairDecimals : opts.tokenDecimals
  const amountIn = parseUnits(String(opts.amount), inDecimals)
  if (amountIn === 0n) throw new Error('Enter an amount first.')

  const balance = await sepoliaClient.readContract({
    address: inToken,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: [opts.account],
  })
  if (balance < amountIn) throw new Error('You do not hold that much.')

  const wallet = walletClient(opts.account)

  // Approve only the shortfall, and only when there is one.
  const allowance = await sepoliaClient.readContract({
    address: inToken,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: [opts.account, TRADE_ROUTER],
  })
  if (allowance < amountIn) {
    onPhase({ kind: 'approving' })
    const approveHash = await wallet.writeContract({
      address: inToken,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [TRADE_ROUTER, amountIn],
      chain: wallet.chain,
      account: opts.account,
    })
    onPhase({ kind: 'approving', hash: approveHash })
    const r = await sepoliaClient.waitForTransactionReceipt({ hash: approveHash })
    if (r.status !== 'success') throw new Error('The approval failed.')
  }

  // Quote by simulating the real call, then set the floor from that.
  const quote = await sepoliaClient.simulateContract({
    address: TRADE_ROUTER,
    abi: TRADE_ROUTER_ABI,
    functionName: 'swap',
    args: [key, zeroForOne, amountIn, 0n, opts.account],
    account: opts.account,
  })
  const expected = quote.result as bigint
  const minOut = (expected * BigInt(10_000 - opts.slippageBps)) / 10_000n

  onPhase({ kind: 'trading' })
  const { request } = await sepoliaClient.simulateContract({
    address: TRADE_ROUTER,
    abi: TRADE_ROUTER_ABI,
    functionName: 'swap',
    args: [key, zeroForOne, amountIn, minOut, opts.account],
    account: opts.account,
  })
  const hash = await wallet.writeContract({ ...request, account: opts.account, chain: wallet.chain })
  onPhase({ kind: 'trading', hash })

  const receipt = await sepoliaClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('The trade reverted.')

  onPhase({ kind: 'done', amountOut: expected, hash })
}

/** What the pool would pay right now, for the preview line. Returns null if it cannot quote. */
export async function quoteTrade(opts: {
  token: Address
  pair: Address
  pairDecimals: number
  tokenDecimals: number
  isBuy: boolean
  amount: number
  account: Address
}): Promise<bigint | null> {
  try {
    const { key, buyIsZeroForOne } = poolKeyFor(opts.token, opts.pair)
    const zeroForOne = opts.isBuy ? buyIsZeroForOne : !buyIsZeroForOne
    const inDecimals = opts.isBuy ? opts.pairDecimals : opts.tokenDecimals
    const amountIn = parseUnits(String(opts.amount), inDecimals)
    if (amountIn === 0n) return null

    const quote = await sepoliaClient.simulateContract({
      address: TRADE_ROUTER,
      abi: TRADE_ROUTER_ABI,
      functionName: 'swap',
      args: [key, zeroForOne, amountIn, 0n, opts.account],
      account: opts.account,
    })
    return quote.result as bigint
  } catch {
    // A pool with no liquidity on the side being taken cannot quote. Say nothing rather than zero.
    return null
  }
}
