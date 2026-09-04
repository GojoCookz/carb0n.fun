/**
 * Turning a filled-in form into a launch transaction.
 *
 * The whole file exists to cross one boundary safely: the form holds human units (5 WETH, "3%",
 * a CID string) and the contract takes machine units (wei, basis points, a 32-byte digest). Every
 * conversion below is one-way and irreversible once mined, so each one is done explicitly and
 * none is done twice.
 */
import { parseUnits, type Address, type Hash } from 'viem'
import { sepoliaClient, DEPLOYMENTS, launchablePairFor, type LaunchablePair } from './chain'
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
  const launcher = DEPLOYMENTS.sepolia.launcher
  if (!launcher) throw new Error('No launcher deployed.')

  const params = buildParams(draft, pair)
  const wallet = walletClient(account)

  if (params.devBuyPairAmount > 0n) {
    const allowance = await sepoliaClient.readContract({
      address: pair.address,
      abi: ERC20_ABI,
      functionName: 'allowance',
      args: [account, launcher],
    })

    if (allowance < params.devBuyPairAmount) {
      const balance = await sepoliaClient.readContract({
        address: pair.address,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [account],
      })
      if (balance < params.devBuyPairAmount) {
        throw new Error(
          `Your opening buy needs ${draft.devBuyPairAmount} ${pair.symbol} and you hold less than that.`,
        )
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
      const receipt = await sepoliaClient.waitForTransactionReceipt({ hash: approveHash })
      if (receipt.status !== 'success') throw new Error('The approval transaction failed.')
    }
  }

  onPhase({ kind: 'launching' })

  const { request, result } = await sepoliaClient.simulateContract({
    address: launcher,
    abi: LAUNCHER_ABI,
    functionName: 'launch',
    args: [params],
    account,
  })

  const hash = await wallet.writeContract({ ...request, account, chain: wallet.chain })
  onPhase({ kind: 'launching', hash })

  const receipt = await sepoliaClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('The launch transaction reverted.')

  // `result` is [token, poolId] from the simulation. The receipt proves it actually happened.
  const token = (Array.isArray(result) ? result[0] : result) as Address
  onPhase({ kind: 'done', token, hash })
}
