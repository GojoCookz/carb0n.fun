/**
 * Buying and selling a launch with ETH, so the buyer never has to source the pair currency.
 *
 * Holders are still paid in the pair currency — that is the product and it has not changed. What
 * this removes is the requirement that the BUYER goes and acquires it first. A `$GOLDFISH` launch
 * paired against PAXG previously asked a first-time buyer to obtain PAXG before pressing Buy.
 *
 *   BUY   ETH --(hop 1: ETH/PAIR pool)--> PAIR --(hop 2: our hooked pool)--> TOKEN
 *   SELL  TOKEN --(hop 2 reversed)--> PAIR --(hop 1 reversed)--> ETH
 *
 * Both hops run inside one `PoolManager.unlock`, so it is one signature and one transaction. See
 * `contracts/src/ZapRouter.sol` — in particular why it swaps first and settles from the resulting
 * deltas, which is the only ordering that is safe against our own hook.
 */
import {
  decodeAbiParameters,
  parseUnits,
  zeroAddress,
  BaseError,
  ContractFunctionRevertedError,
  type Address,
} from 'viem'
import { sepoliaClient, DEPLOYMENTS, ethPoolFeeFor } from './chain'
import { ERC20_ABI } from './abi'
import { walletClient } from './wallet'
import { poolKeyFor, type TradePhase } from './tradeTx'

export const ZAP_ROUTER = DEPLOYMENTS.sepolia.zapRouter as Address

/** Every launch opens with this spacing, and the ETH pool was seeded to match. */
const TICK_SPACING = 60

/** How long a signed zap stays valid. Uniswap's own default. */
const DEADLINE_SECONDS = 20 * 60

const POOL_KEY_TUPLE = {
  name: 'key',
  type: 'tuple',
  components: [
    { name: 'currency0', type: 'address' },
    { name: 'currency1', type: 'address' },
    { name: 'fee', type: 'uint24' },
    { name: 'tickSpacing', type: 'int24' },
    { name: 'hooks', type: 'address' },
  ],
} as const

export const ZAP_ROUTER_ABI = [
  {
    name: 'zapBuy',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      { ...POOL_KEY_TUPLE, name: 'ethKeys', type: 'tuple[]' },
      { ...POOL_KEY_TUPLE, name: 'tokenKey' },
      { name: 'minAmountOut', type: 'uint256' },
      { name: 'recipient', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
  {
    name: 'zapSell',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { ...POOL_KEY_TUPLE, name: 'ethKeys', type: 'tuple[]' },
      { ...POOL_KEY_TUPLE, name: 'tokenKey' },
      { name: 'amountIn', type: 'uint256' },
      { name: 'minAmountOut', type: 'uint256' },
      { name: 'recipient', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
  {
    name: 'quoteZapBuy',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { ...POOL_KEY_TUPLE, name: 'ethKeys', type: 'tuple[]' },
      { ...POOL_KEY_TUPLE, name: 'tokenKey' },
      { name: 'amountIn', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'quoteZapSell',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { ...POOL_KEY_TUPLE, name: 'ethKeys', type: 'tuple[]' },
      { ...POOL_KEY_TUPLE, name: 'tokenKey' },
      { name: 'amountIn', type: 'uint256' },
    ],
    outputs: [],
  },
  // The quote channel. Reverting with the answer is what makes it impossible to use a quote call
  // to execute a floorless swap, and it is why a quote needs neither a balance nor an approval.
  { name: 'ZapQuote', type: 'error', inputs: [{ name: 'amountOut', type: 'uint256' }] },
  { name: 'NoSlippageFloor', type: 'error', inputs: [] },
  { name: 'ZeroAmount', type: 'error', inputs: [] },
  {
    name: 'Expired',
    type: 'error',
    inputs: [
      { name: 'deadline', type: 'uint256' },
      { name: 'nowTimestamp', type: 'uint256' },
    ],
  },
  { name: 'EthLegIsNotNative', type: 'error', inputs: [] },
  { name: 'PairIsNotInTheLaunchPool', type: 'error', inputs: [] },
  {
    name: 'PoolIsPinnedAtItsPriceLimit',
    type: 'error',
    inputs: [{ name: 'zeroForOne', type: 'bool' }],
  },
  {
    name: 'IntermediateLegDidNotNet',
    type: 'error',
    inputs: [{ name: 'residual', type: 'int256' }],
  },
  {
    name: 'TooLittleReceived',
    type: 'error',
    inputs: [
      { name: 'got', type: 'uint256' },
      { name: 'minOut', type: 'uint256' },
    ],
  },
] as const

/**
 * Hop 1's key: native ether against the pair currency.
 *
 * **Native ether is `address(0)`, so it sorts to `currency0` unconditionally** — there is no
 * ordering question here the way there is for a launch pool. `ZapRouter` checks exactly this and
 * rejects anything else, so a key built the other way round fails loudly rather than routing
 * through some other asset.
 *
 * Returns null when no ETH pool has been verified for this pair. The caller must not offer ETH in
 * that case: the swap would revert `PoolNotInitialized`, which a user reads as a broken token.
 */
export function ethPoolKeyFor(pair: Address) {
  const fee = ethPoolFeeFor(pair)
  if (fee === null) return null
  return ethKeyAt(pair, fee, TICK_SPACING)
}

function ethKeyAt(pair: Address, fee: number, tickSpacing: number) {
  return {
    currency0: zeroAddress as Address,
    currency1: pair.toLowerCase() as Address,
    fee,
    tickSpacing,
    hooks: zeroAddress as Address,
  }
}

/**
 * The canonical Uniswap fee tiers and their tick spacings.
 *
 * Offering all of them is the point: `ZapRouter` takes the first that is not pinned, so a pair with
 * pools at several tiers is one an attacker has to exhaust several times per block instead of once.
 */
const TIERS: ReadonlyArray<readonly [number, number]> = [
  [100, 1],
  [500, 10],
  [3000, 60],
  [10000, 200],
]

/**
 * EVERY hop-1 candidate for this pair, best-known first.
 *
 * **This is the Z-14 fix on the client side, and passing one key would make the contract fix
 * inert.** A stranger can exhaust a single ETH pool and park it on its price limit; with only that
 * pool offered, every zap sell reverts for every holder until somebody trades it back off. Cost to
 * the attacker was measured at 0.69% of what they pushed through, and it re-arms every block.
 *
 * The verified tier from `ethRoute.ts` goes first because it is the one actually measured for
 * depth. The other canonical tiers follow as fallbacks — an uninitialised pool is not pinned, it is
 * absent, and the router treats those differently, so listing a tier that does not exist is
 * harmless rather than a silent misroute.
 */
export function ethPoolKeysFor(pair: Address) {
  const best = ethPoolFeeFor(pair)
  if (best === null) return []

  const bestSpacing = TIERS.find(([f]) => f === best)?.[1] ?? TICK_SPACING
  const keys = [ethKeyAt(pair, best, bestSpacing)]
  for (const [fee, spacing] of TIERS) {
    if (fee !== best) keys.push(ethKeyAt(pair, fee, spacing))
  }
  return keys
}

/** True when this launch can be traded in ETH at all. */
export function zapAvailable(pair: Address | null): boolean {
  return Boolean(ZAP_ROUTER) && pair !== null && ethPoolFeeFor(pair) !== null
}

/**
 * Pull the amount out of the `ZapQuote` revert.
 *
 * viem surfaces a decoded custom error when the ABI declares it, so this walks the error chain
 * rather than string-matching a message. Anything that is not `ZapQuote` is a real failure and is
 * rethrown: swallowing it here would turn "this pool cannot be traded" into a silent `null` and the
 * panel would show a dash with no reason.
 */
function amountFromQuoteRevert(err: unknown): bigint {
  if (err instanceof BaseError) {
    const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError)
    if (reverted instanceof ContractFunctionRevertedError) {
      const data = reverted.data
      if (data?.errorName === 'ZapQuote') return data.args?.[0] as bigint
      // A raw revert with data viem could not match against the ABI. Decode by selector.
      const raw = (reverted.raw ?? '') as string
      if (raw.startsWith('0x') && raw.length > 10) {
        try {
          const [amount] = decodeAbiParameters(
            [{ type: 'uint256' }],
            `0x${raw.slice(10)}` as `0x${string}`,
          )
          return amount as bigint
        } catch {
          /* fall through to the rethrow */
        }
      }
    }
  }
  throw err
}

export type ZapArgs = {
  token: Address
  pair: Address
  pairDecimals: number
  tokenDecimals: number
  /** True to spend ETH and receive the launch token. */
  isBuy: boolean
  /** Human amount of whichever asset is being SPENT — ether on a buy, the token on a sell. */
  amount: number
  account: Address
}

/** What the two hops would return right now. Null when the route cannot be quoted at all. */
export async function quoteZap(opts: ZapArgs): Promise<bigint | null> {
  const ethKeys = ethPoolKeysFor(opts.pair)
  if (ethKeys.length === 0 || !ZAP_ROUTER) return null

  const { key: tokenKey } = poolKeyFor(opts.token, opts.pair)
  const inDecimals = opts.isBuy ? 18 : opts.tokenDecimals
  const amountIn = parseUnits(String(opts.amount), inDecimals)
  if (amountIn === 0n) return null

  try {
    await sepoliaClient.simulateContract({
      address: ZAP_ROUTER,
      abi: ZAP_ROUTER_ABI,
      functionName: opts.isBuy ? 'quoteZapBuy' : 'quoteZapSell',
      args: [ethKeys, tokenKey, amountIn],
      account: opts.account,
    })
    // The quote functions always revert. Reaching here means the deployed bytecode is not the
    // contract this file was written against, which is worth surfacing rather than guessing.
    return null
  } catch (err) {
    try {
      return amountFromQuoteRevert(err)
    } catch {
      // A pool at its price limit, or no liquidity on the side being taken. Say nothing, not zero.
      return null
    }
  }
}

/**
 * Approve if needed, then zap.
 *
 * **The floor is not optional and `ZapRouter` rejects a zero one.** A swap with no floor is an
 * instruction to accept any price, which on a thin pool is an instruction to be sandwiched. The
 * quote is taken first so the floor comes from what the route would actually pay right now.
 */
export async function submitZap(
  opts: ZapArgs & { slippageBps: number },
  onPhase: (p: TradePhase) => void,
): Promise<void> {
  const ethKeys = ethPoolKeysFor(opts.pair)
  if (ethKeys.length === 0 || !ZAP_ROUTER) throw new Error('There is no ETH pool for this pair yet.')

  const { key: tokenKey } = poolKeyFor(opts.token, opts.pair)
  const inDecimals = opts.isBuy ? 18 : opts.tokenDecimals
  const amountIn = parseUnits(String(opts.amount), inDecimals)
  if (amountIn === 0n) throw new Error('Enter an amount first.')

  const wallet = walletClient(opts.account)

  if (opts.isBuy) {
    const balance = await sepoliaClient.getBalance({ address: opts.account })
    if (balance < amountIn) throw new Error('You do not hold that much ETH.')
  } else {
    const balance = await sepoliaClient.readContract({
      address: opts.token,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [opts.account],
    })
    if (balance < amountIn) throw new Error('You do not hold that many tokens.')

    // Only the sell side needs an approval. A buy pays in native ether, which is the whole reason
    // the ETH path is one click and the pair path is two.
    const allowance = await sepoliaClient.readContract({
      address: opts.token,
      abi: ERC20_ABI,
      functionName: 'allowance',
      args: [opts.account, ZAP_ROUTER],
    })
    if (allowance < amountIn) {
      onPhase({ kind: 'approving' })
      const approveHash = await wallet.writeContract({
        address: opts.token,
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [ZAP_ROUTER, amountIn],
        chain: wallet.chain,
        account: opts.account,
      })
      onPhase({ kind: 'approving', hash: approveHash })
      const r = await sepoliaClient.waitForTransactionReceipt({ hash: approveHash })
      if (r.status !== 'success') throw new Error('The approval failed.')
    }
  }

  const expected = await quoteZap(opts)
  if (expected === null || expected === 0n) {
    throw new Error('This route cannot be quoted right now, so there is no safe price to set.')
  }
  // A floor of zero is rejected on chain, and a floor of zero is what a 100% slippage setting
  // would produce here, so clamp to one unit.
  const floor = (expected * BigInt(10_000 - opts.slippageBps)) / 10_000n
  const minOut = floor === 0n ? 1n : floor

  // **The floor bounds price; this bounds TIME.** A transaction can sit unmined and then land into
  // a market the quote no longer describes, and a floor derived from a stale quote is not
  // protective. Twenty minutes is Uniswap's own default.
  const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS)

  onPhase({ kind: 'trading' })
  const { request } = await sepoliaClient.simulateContract({
    address: ZAP_ROUTER,
    abi: ZAP_ROUTER_ABI,
    ...(opts.isBuy
      ? {
          functionName: 'zapBuy' as const,
          args: [ethKeys, tokenKey, minOut, opts.account, deadline] as const,
          value: amountIn,
        }
      : {
          functionName: 'zapSell' as const,
          args: [ethKeys, tokenKey, amountIn, minOut, opts.account, deadline] as const,
        }),
    account: opts.account,
  })
  const hash = await wallet.writeContract({ ...request, account: opts.account, chain: wallet.chain })
  onPhase({ kind: 'trading', hash })

  const receipt = await sepoliaClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('The zap reverted.')

  onPhase({ kind: 'done', amountOut: expected, hash })
}
