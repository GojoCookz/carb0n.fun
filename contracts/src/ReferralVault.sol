// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ReferralVault
/// @notice Receives the platform's cut and splits it between referrers and the treasury.
///
/// @dev **This is a LEDGER, not a payer.** Nothing here transfers on the hot path. A sweep credits
///      balances and every recipient withdraws their own, for three reasons:
///
///       1. **Gas.** Paying five tiers inside a swap on L1 is five storage writes plus five token
///          transfers on the single hottest path in the system, charged to whoever happened to be
///          trading. A ledger makes it five writes on the already-heavy sweep path and nothing at
///          all on a swap.
///       2. **Griefing.** A referrer that reverts on receipt, or a blocklisting pair currency,
///          would otherwise brick the sweep for everyone downstream of them.
///       3. **One claim, not N.** `owed` is keyed by (recipient, currency), NOT by pool, so a
///          referrer with fifty referred launches against WETH claims all fifty at once.
///
///      **On the shape of the tiers.** Multi-level payouts on recruitment depth are pyramid-shaped
///      and that is FTC territory. Two properties keep this on the right side of the line and both
///      are structural rather than promises:
///
///       - **Nobody pays to join and nothing is earned for recruiting.** A referrer earns only
///         when a launch they referred does real trading volume. There is no signup fee, no
///         purchase requirement, and no payment for the act of referring.
///       - **The tiers are fixed at deploy and cannot be extended.** `MAX_TIERS` is a hard cap in
///         the bytecode, and the whole schedule is immutable, so the structure cannot be deepened
///         later to chase growth.
///
///      That is a real defence, not a complete one. It is not legal advice and this should be
///      reviewed by someone qualified before it pays a single referrer on mainnet.
contract ReferralVault {
    /// @notice Hard ceiling on referral depth. In the bytecode so it cannot be raised later.
    uint8 public constant MAX_TIERS = 5;
    uint16 public constant BPS = 10_000;

    /// @notice The launcher, the only contract allowed to record who referred a creator.
    address public immutable launcher;
    /// @notice The fee hook, the only contract allowed to credit earnings.
    address public immutable feeHook;
    /// @notice Where everything not owed to a referrer goes.
    address public immutable treasury;

    /// @notice Share of the platform cut paid at each tier, index 0 being the direct referrer.
    /// @dev Immutable after deploy. Stored as a fixed array plus a length so the whole schedule
    ///      reads in one slot and cannot be pushed to.
    uint16[MAX_TIERS] internal _tierBps;
    uint8 public immutable tierCount;

    /// @notice Who referred an address. Written once, never changed.
    /// @dev Permanent by design: a mutable referrer is a mutable revenue claim, and rewriting it
    ///      after the fact is how a referral graph turns into a dispute.
    mapping(address user => address referrer) public referrerOf;

    /// @notice Claimable balance, per recipient per currency. NOT per pool.
    mapping(address recipient => mapping(address currency => uint256)) public owed;

    /// @notice Lifetime earnings, per recipient per currency. Diagnostics only.
    mapping(address recipient => mapping(address currency => uint256)) public earned;

    event ReferrerSet(address indexed user, address indexed referrer);
    event Credited(address indexed currency, uint256 amount, address indexed creator);
    event ReferralEarned(
        address indexed referrer, address indexed currency, uint256 amount, uint8 tier
    );
    event Claimed(address indexed recipient, address indexed currency, uint256 amount);

    error OnlyLauncher();
    error OnlyFeeHook();
    error ZeroAddress();
    error AlreadyReferred();
    error SelfReferral();
    error TooManyTiers();
    error TiersExceedWhole();
    error NothingOwed();
    error TransferFailed();

    constructor(address _launcher, address _feeHook, address _treasury, uint16[] memory schedule) {
        if (_launcher == address(0) || _feeHook == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        if (schedule.length > MAX_TIERS) revert TooManyTiers();

        uint256 total;
        for (uint256 i = 0; i < schedule.length; i++) {
            _tierBps[i] = schedule[i];
            total += schedule[i];
        }
        // The referral schedule is paid OUT OF the platform's cut, so it cannot exceed it.
        // Without this the treasury underflows and the vault owes more than it holds.
        if (total > BPS) revert TiersExceedWhole();

        launcher = _launcher;
        feeHook = _feeHook;
        treasury = _treasury;
        tierCount = uint8(schedule.length);
    }

    /// @notice The full referral schedule, for display.
    function tiers() external view returns (uint16[] memory out) {
        out = new uint16[](tierCount);
        for (uint256 i = 0; i < tierCount; i++) {
            out[i] = _tierBps[i];
        }
    }

    /// @notice Record who referred a creator. Called by the launcher during `launch`.
    ///
    /// @dev Silently ignores a repeat rather than reverting: a creator's SECOND launch must not
    ///      fail because they arrived through a different link. The first one stands.
    function setReferrer(address user, address referrer) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (referrer == address(0) || user == address(0)) return;
        if (referrer == user) revert SelfReferral();
        if (referrerOf[user] != address(0)) return;

        referrerOf[user] = referrer;
        emit ReferrerSet(user, referrer);
    }

    /// @notice Credit a platform fee that has already been transferred to this contract.
    ///
    /// @dev **Called AFTER the tokens land, and it never pulls.** The hook transfers first and
    ///      calls this second, inside a try/catch, so a revert here can never brick a sweep. The
    ///      cost of that is that this trusts the hook about the amount - which is why only the
    ///      hook may call it.
    ///
    ///      Walks up the referral chain, paying each tier a share.
    ///
    ///      **CYCLES ARE LEGAL AND THE WALK IS WHAT MAKES THEM HARMLESS.** This used to claim
    ///      cycles were impossible "because `referrerOf` is write-once and a referrer must
    ///      already exist when they refer someone". Only the first half was ever enforced.
    ///      `setReferrer` has no check that the referrer is already in the graph - and it cannot
    ///      have one, or the first referrer of all could never be recorded - so
    ///      `A -> B` then `B -> A` is two ordinary legal launches. The walk then alternated
    ///      `B, A, B, A, B` and paid a creator's own two wallets **the entire 40% schedule**,
    ///      measured, and withdrawable.
    ///
    ///      The fix is here rather than in `setReferrer`: **no address is paid twice in one walk,
    ///      and the creator is never paid at all.** A cycle now earns exactly what one honest
    ///      referrer earns - tier 0 - and the walk terminates at the first repeat. The seen-set is
    ///      a fixed `MAX_TIERS + 1` memory array, so the quadratic scan is at most 21 comparisons
    ///      and cannot be grown by attacker-shaped data.
    ///
    ///      What this does NOT close is a chain of five DISTINCT sybil wallets, which is a bounded,
    ///      known 40% haircut on referral revenue (`sum(schedule)`, `MAX_TIERS` both fixed in the
    ///      bytecode) and is a schedule-design question, not a correctness one.
    function credit(address currency, uint256 amount, address creator) external {
        if (msg.sender != feeHook) revert OnlyFeeHook();
        if (amount == 0) return;

        emit Credited(currency, amount, creator);

        uint256 remaining = amount;
        address walker = referrerOf[creator];

        // Seeded with the creator, so a cycle can never route the platform's cut back to the
        // person whose launch generated it.
        address[MAX_TIERS + 1] memory seen;
        seen[0] = creator;
        uint256 seenCount = 1;

        for (uint8 i = 0; i < tierCount; i++) {
            if (walker == address(0)) break;

            bool alreadyPaid;
            for (uint256 j = 0; j < seenCount; j++) {
                if (seen[j] == walker) {
                    alreadyPaid = true;
                    break;
                }
            }
            // The chain has run out of distinct people. Everything left goes to the treasury.
            if (alreadyPaid) break;
            seen[seenCount] = walker;
            unchecked {
                ++seenCount;
            }

            uint256 cut = (amount * _tierBps[i]) / BPS;
            if (cut != 0) {
                // Cannot exceed `remaining` because the constructor caps the schedule at 100%.
                remaining -= cut;
                owed[walker][currency] += cut;
                earned[walker][currency] += cut;
                emit ReferralEarned(walker, currency, cut, i);
            }
            walker = referrerOf[walker];
        }

        // Everything not owed to a referrer - including every tier nobody occupies.
        if (remaining != 0) {
            owed[treasury][currency] += remaining;
            earned[treasury][currency] += remaining;
        }
    }

    /// @notice Withdraw everything owed to the caller in one currency.
    /// @dev Effects before interaction, and the balance is zeroed before the transfer, so a
    ///      reentrant token sees nothing left to claim.
    function claim(address currency) external returns (uint256 amount) {
        amount = owed[msg.sender][currency];
        if (amount == 0) revert NothingOwed();

        owed[msg.sender][currency] = 0;
        if (!_send(currency, msg.sender, amount)) {
            owed[msg.sender][currency] = amount; // restore; a failed claim must not burn it
            revert TransferFailed();
        }
        emit Claimed(msg.sender, currency, amount);
    }

    /// @dev Handles both bool-returning and no-return ERC-20s.
    function _send(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
