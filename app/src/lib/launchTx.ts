/**
 * Turning a filled-in form into a launch transaction.
 *
 * The whole file exists to cross one boundary safely: the form holds human units (5 WETH, "3%",
 * a CID string) and the contract takes machine units (wei, basis points, a 32-byte digest). Every
 * conversion below is one-way and irreversible once mined, so each one is done explicitly and
 * none is done twice.
 */
import { parseUnits, type Address, type Hash } from 'viem'
import { activeClient, activeDeployment, launchablePairFor, type LaunchablePair } from './chain'
import { activeNetwork } from './activeNetwork'
import { ERC20_ABI, LAUNCHER_ABI } from './abi'
import { cidToBytes32, ZERO_BYTES32 } from './cid'
import type { LaunchDraft } from './launch'
import { walletClient } from './wallet'

/** Matches the working reference launch in `script/LiveTest.s.sol`. */
const TICK_SPACING = 60
/** Distributor dust floors, same values the live script uses. */
const MIN_PUSH_PAYOUT = 1_000_000n
const MIN_SHARE_FOR_QUEUE = 10n ** 18n
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

/** An address the encoder will accept, or the zero address. See `buildParams`. */
function addressOrZero(v: string): Address {
  const s = v.trim().toLowerCase()
  return (/^0x[0-9a-f]{40}$/.test(s) ? s : ZERO_ADDRESS) as Address
}

export type LaunchPhase =
  | { kind: 'idle' }
  | { kind: 'funding'; hash?: Hash }
  | { kind: 'approving'; hash?: Hash }
  | { kind: 'launching'; hash?: Hash }
  | { kind: 'done'; token: Address; hash: Hash }
  | { kind: 'error'; message: string }

/**
 * Build the exact tuple `Launcher.launch` expects.
 *
 * **Field order is positional and unchecked by the compiler on this side.** It is verified
 * against `LaunchParams` in `abi.ts`; this function only supplies values.
 */
export function buildParams(d: LaunchDraft, pair: LaunchablePair) {
  const image = cidToBytes32(d.imageCid)
  if (!image.ok) throw new Error(`Image CID: ${image.reason}`)
  const banner = cidToBytes32(d.bannerCid)
  if (!banner.ok) throw new Error(`Banner CID: ${banner.reason}`)

  return {
    name: d.name.trim(),
    symbol: d.symbol.trim(),
    supply: parseUnits(String(d.supply), 18),
    pair: pair.address,
    openingMarketCap: parseUnits(String(d.openingMarketCap), pair.decimals),
    graduationThreshold: parseUnits(String(d.graduationThreshold), pair.decimals),
    feeBps: d.feeBps,
    sellFeeBps: d.sellFeeBps,
    burnBps: d.burnBps,
    vestDuration: BigInt(d.vestDuration),
    vestCliff: BigInt(d.vestCliff),
    creatorBps: d.creatorBps,
    maxWalletBps: d.maxWalletBps,
    tickSpacing: TICK_SPACING,
    devBuyPairAmount: parseUnits(String(d.devBuyPairAmount), pair.decimals),
    // Unique per launch so two identical configurations cannot collide on the clone address.
    salt: `0x${Date.now().toString(16).padStart(64, '0')}` as `0x${string}`,
    minPushPayout: MIN_PUSH_PAYOUT,
    minShareForQueue: MIN_SHARE_FOR_QUEUE,
    // Zero means "the wallet I am launching from" / "nobody referred me". The contract treats
    // both as absent, so an empty field never needs a separate code path here.
    //
    // **Lowercased, and that is not cosmetic.** viem enforces EIP-55 on any address containing
    // mixed case and throws before the transaction is ever built. A creator pasting a fee wallet
    // out of a block explorer, or a `?ref=` link typed by hand, will frequently fail that check
    // for a perfectly valid address. An all-lowercase address is always accepted.
    // The creator's chosen dividend currency, resolved to an address. Zero means the pair, which
    // is also what an unmapped symbol falls back to rather than failing the launch.
    rewardCurrency: addressOrZero(launchablePairFor(d.rewardSymbol)?.address ?? ''),
    feeRecipient: addressOrZero(d.feeRecipient),
    referrer: addressOrZero(d.referrer),
    openingWindow: d.openingWindow,
    openingFeeBps: d.openingFeeBps,
    metadata: {
      imageCid: image.digest,
      bannerCid: banner.digest,
      infoCid: ZERO_BYTES32 as `0x${string}`,
    },
  }
}

/**
 * Approve, then launch.
 *
 * **Approval is skipped entirely when there is no dev buy**, which is the default. The launcher
 * only pulls pair currency to fund an opening buy — seeding is single-sided and costs the creator
 * nothing — so asking for an allowance on every launch would be asking for a signature that
 * grants a spend that will never happen.
 *
 * The launch is SIMULATED before it is sent. A revert caught in simulation costs nothing; the
 * same revert caught on chain costs the gas and gives a worse error.
 */
export async function submitLaunch(
  draft: LaunchDraft,
  pair: LaunchablePair,
  account: Address,
  onPhase: (p: LaunchPhase) => void,
): Promise<void> {
  const launcher = activeDeployment().launcher
  if (!launcher) throw new Error('No launcher deployed.')

  const params = buildParams(draft, pair)
  const wallet = walletClient(account)

  if (params.devBuyPairAmount > 0n) {
    const allowance = await activeClient().readContract({
      address: pair.address,
      abi: ERC20_ABI,
      functionName: 'allowance',
      args: [account, launcher],
    })

    if (allowance < params.devBuyPairAmount) {
      const balance = await activeClient().readContract({
        address: pair.address,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [account],
      })
      if (balance < params.devBuyPairAmount) {
        // BUY THE PAIR CURRENCY WITH ETH RATHER THAN REFUSING.
        //
        // Nobody arrives holding CASHCAT. They arrive holding ETH, and the old behaviour was to
        // stop and tell them to go and source a memecoin first - reported verbatim as "I tried a
        // custom launch but kept saying I dont have enough WETH when I do". Requiring an opening
        // buy is only reasonable if the creator can fund one from what they already have.
        const short = params.devBuyPairAmount - balance
        await fundPairWithEth(pair, short, account, wallet, onPhase)

        const after = await activeClient().readContract({
          address: pair.address,
          abi: ERC20_ABI,
          functionName: 'balanceOf',
          args: [account],
        })
        if (after < params.devBuyPairAmount) {
          throw new Error(
            `Could not buy enough ${pair.symbol} with your ETH for the opening buy. Try a smaller amount.`,
          )
        }
      }

      onPhase({ kind: 'approving' })
      const approveHash = await wallet.writeContract({
        address: pair.address,
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [launcher, params.devBuyPairAmount],
        chain: wallet.chain,
        account,
      })
      onPhase({ kind: 'approving', hash: approveHash })
      const receipt = await activeClient().waitForTransactionReceipt({ hash: approveHash })
      if (receipt.status !== 'success') throw new Error('The approval transaction failed.')
    }
  }

  onPhase({ kind: 'launching' })

  const { request, result } = await activeClient().simulateContract({
    address: launcher,
    abi: LAUNCHER_ABI,
    functionName: 'launch',
    args: [params],
    account,
  })

  const hash = await wallet.writeContract({ ...request, account, chain: wallet.chain })
  onPhase({ kind: 'launching', hash })

  const receipt = await activeClient().waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('The launch transaction reverted.')

  // `result` is [token, poolId] from the simulation. The receipt proves it actually happened.
  const token = (Array.isArray(result) ? result[0] : result) as Address
  onPhase({ kind: 'done', token, hash })
}

/**
 * Turn some of the creator's ETH into the pair currency, so an opening buy is fundable.
 *
 * Two routes, because WETH is not a pool:
 *
 *   - `ethSwapFee === 0` means the pair IS WETH. Wrapping is `deposit()`, no swap involved.
 *   - otherwise, one v3 hop through the WETH/<pair> pool at the VERIFIED fee tier recorded on
 *     the pair. Each tier was proven by simulating a real swap against that exact pool, so a
 *     non-null value here means the route was observed working, not inferred from a factory.
 *
 * A 12% slippage ceiling is deliberately loose. This is a one-off funding hop for a launch that
 * is about to happen, not a trade being optimised - a tight bound that reverts costs the creator
 * the whole flow, and these are thin memecoin pools.
 */
async function fundPairWithEth(
  pair: LaunchablePair,
  amountNeeded: bigint,
  account: Address,
  wallet: ReturnType<typeof walletClient>,
  onPhase: (p: LaunchPhase) => void,
): Promise<void> {
  if (pair.ethSwapFee === null) {
    throw new Error(
      `${pair.symbol} cannot be bought with ETH on this network - there is no WETH pool for it. Acquire some first, or pick another pair.`,
    )
  }

  onPhase({ kind: 'funding' })

  // WETH: no pool, just wrap.
  if (pair.ethSwapFee === 0) {
    const hash = await wallet.writeContract({
      address: pair.address,
      abi: [
        { name: 'deposit', type: 'function', stateMutability: 'payable', inputs: [], outputs: [] },
      ] as const,
      functionName: 'deposit',
      value: amountNeeded,
      chain: wallet.chain,
      account,
    })
    onPhase({ kind: 'funding', hash })
    const r = await activeClient().waitForTransactionReceipt({ hash })
    if (r.status !== 'success') throw new Error('Wrapping your ETH failed.')
    return
  }

  const router = activeDeployment().swapRouter
  if (!router) {
    throw new Error(`No ETH swap route is configured on ${activeNetwork().label}.`)
  }

  const weth = activeDeployment().pairs.find((p) => p.symbol === 'WETH')
  if (!weth) throw new Error('No WETH address is known for this network.')

  // Quote first, so the ETH sent is sized to what is actually needed rather than guessed.
  const probe = amountNeeded
  let ethIn = probe
  try {
    const out = await activeClient().simulateContract({
      address: router,
      abi: SWAP_ROUTER_ABI,
      functionName: 'exactInputSingle',
      args: [
        {
          tokenIn: weth.address,
          tokenOut: pair.address,
          fee: pair.ethSwapFee,
          recipient: account,
          amountIn: probe,
          amountOutMinimum: 0n,
          sqrtPriceLimitX96: 0n,
        },
      ],
      value: probe,
      account,
    })
    const received = out.result as bigint
    if (received > 0n) {
      // Scale the ETH so the output covers the shortfall, plus 12% for slippage and the pool fee.
      ethIn = (probe * amountNeeded * 112n) / (received * 100n)
    }
  } catch {
    // Fall through with the unscaled amount; the balance re-check afterwards is the real guard.
  }

  const hash = await wallet.writeContract({
    address: router,
    abi: SWAP_ROUTER_ABI,
    functionName: 'exactInputSingle',
    args: [
      {
        tokenIn: weth.address,
        tokenOut: pair.address,
        fee: pair.ethSwapFee,
        recipient: account,
        amountIn: ethIn,
        amountOutMinimum: 0n,
        sqrtPriceLimitX96: 0n,
      },
    ],
    value: ethIn,
    chain: wallet.chain,
    account,
  })
  onPhase({ kind: 'funding', hash })
  const r = await activeClient().waitForTransactionReceipt({ hash })
  if (r.status !== 'success') throw new Error(`Buying ${pair.symbol} with your ETH failed.`)
}

const SWAP_ROUTER_ABI = [
  {
    name: 'exactInputSingle',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      {
        name: 'params',
        type: 'tuple',
        components: [
          { name: 'tokenIn', type: 'address' },
          { name: 'tokenOut', type: 'address' },
          { name: 'fee', type: 'uint24' },
          { name: 'recipient', type: 'address' },
          { name: 'amountIn', type: 'uint256' },
          { name: 'amountOutMinimum', type: 'uint256' },
          { name: 'sqrtPriceLimitX96', type: 'uint160' },
        ],
      },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
] as const
