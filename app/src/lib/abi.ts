/**
 * The only ABI fragments the app sends transactions with.
 *
 * **Hand-written against `src/Launcher.sol`, not pasted from a build artifact**, because the
 * artifact carries 40 other functions the frontend must never call and going through them one by
 * one is how a launcher's admin surface ends up wired to a button.
 *
 * The struct order below is LOAD-BEARING. Solidity encodes a struct positionally, so a field in
 * the wrong slot does not fail — it succeeds with `feeBps` read as `sellFeeBps`, or a 365-day
 * vest read as a cliff. There is no revert to catch that, and a launch cannot be undone.
 * If `LaunchParams` in the Solidity ever changes, this changes in the same commit.
 *
 * Verified field-for-field against Launcher.sol lines 107-133 (19 fields, metadata nested last).
 */

export const LAUNCH_PARAMS_COMPONENTS = [
  { name: 'name', type: 'string' },
  { name: 'symbol', type: 'string' },
  { name: 'supply', type: 'uint256' },
  { name: 'pair', type: 'address' },
  { name: 'openingMarketCap', type: 'uint256' },
  { name: 'graduationThreshold', type: 'uint256' },
  { name: 'feeBps', type: 'uint16' },
  { name: 'sellFeeBps', type: 'uint16' },
  { name: 'burnBps', type: 'uint16' },
  { name: 'vestDuration', type: 'uint64' },
  { name: 'vestCliff', type: 'uint64' },
  { name: 'creatorBps', type: 'uint16' },
  { name: 'maxWalletBps', type: 'uint16' },
  { name: 'tickSpacing', type: 'int24' },
  { name: 'devBuyPairAmount', type: 'uint256' },
  { name: 'salt', type: 'bytes32' },
  { name: 'minPushPayout', type: 'uint256' },
  { name: 'minShareForQueue', type: 'uint256' },
  { name: 'rewardCurrency', type: 'address' },
  { name: 'feeRecipient', type: 'address' },
  { name: 'referrer', type: 'address' },
  // The E-01 mitigation. Zero window disables it and the launch behaves as it always did.
  { name: 'openingWindow', type: 'uint32' },
  { name: 'openingFeeBps', type: 'uint16' },
  {
    name: 'metadata',
    type: 'tuple',
    components: [
      { name: 'imageCid', type: 'bytes32' },
      { name: 'bannerCid', type: 'bytes32' },
      { name: 'infoCid', type: 'bytes32' },
    ],
  },
] as const

export const LAUNCHER_ABI = [
  {
    name: 'launch',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'p', type: 'tuple', components: LAUNCH_PARAMS_COMPONENTS }],
    outputs: [
      { name: 'token', type: 'address' },
      { name: 'poolId', type: 'bytes32' },
    ],
  },
  {
    name: 'launchCount',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'vaultOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    // The launcher's own record of every launch, in order. This is what the board reads instead
    // of an indexer — see `useLaunches`.
    name: 'launches',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'uint256' }],
    outputs: [
      { name: 'token', type: 'address' },
      { name: 'creator', type: 'address' },
      { name: 'pair', type: 'address' },
      { name: 'launchedAt', type: 'uint64' },
    ],
  },
] as const

export const PAIR_REGISTRY_ABI = [
  {
    name: 'isApproved',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'pair', type: 'address' }],
    outputs: [{ name: '', type: 'bool' }],
  },
] as const

/**
 * Only what the launch path needs. No `transfer`, no `transferFrom` — the app has no business
 * moving a user's tokens anywhere except into an allowance the launcher spends.
 */
export const ERC20_ABI = [
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'decimals',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint8' }],
  },
] as const
