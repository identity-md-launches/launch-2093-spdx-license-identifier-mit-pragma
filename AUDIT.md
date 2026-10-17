# Super IMD review and repair record

The review covers the two Solidity bodies supplied in the task, the added guarded base, hook factory, offline salt utility, and their interaction with the pinned dependencies. The requested economics are one billion SIMD with fee-free transfers and a fixed 2% hook fee on buys and sells. No deployed addresses or bytecode were supplied. This is a bounded source review with repairs and local adversarial tests, not an independent review of a live deployment.

The original `./base/BaseHook.sol` was not supplied. Findings about the supplied hook body are reproduced against a base that authenticates the manager and validates permissions. This intentionally avoids claiming that the unavailable original base had an access-control defect. The original-body fixtures are in `test/helpers/HookFixtures.sol`; they are not launch contracts.

## Findings and changes

| ID | Severity | Concrete behavior in original | Delivered disposition |
| --- | --- | --- | --- |
| SIMD-01 | Medium, availability | A fee beneficiary that rejects ETH causes every native-fee swap to revert | Fees accrue as claims; separate authorized collection |
| SIMD-02 | Low, configuration | The token accepts supply values inconsistent with the requested one billion whole SIMD | Constructor enforces exactly `10**27` base units |
| SIMD-03 | Low, pool scope | `projectToken` is never used; unrelated pools are charged identically | Swap-time pool identity/token-membership checks |
| SIMD-04 | Informational, arithmetic | Negating `type(int128).min` panics in an isolated callback | Widen to `int256` before taking magnitude; core settlement limits still apply |
| SIMD-05 | Deployment/integration prerequisite | Missing base and unmined deployment cannot establish v4 callback permissions | Guarded base, strict address-bit validation, configured CREATE2 factory and tested miner |

No critical or high-severity loss-of-funds exploit was demonstrated in the supplied bodies. That conclusion is limited to the reviewed source and assumptions below.

### SIMD-01 — recipient failure propagates into trading

**Trigger:** a SIMD/ETH pool uses a fee recipient whose `receive()` reverts. An exact-input SIMD-to-ETH swap executes and the original hook invokes `poolManager.take(ETH, feeRecipient, fee)`. PoolManager's native transfer fails, the hook call fails, and the swap reverts. An ETH-to-SIMD exact-output buy also charges ETH and has the same dependency. Expected trading availability depends only on pool accounting and valid trader settlement; actual availability also depends on a push payment to a permanently fixed recipient.

**Evidence:** `test_regressionOriginalRecipientRejectionRevertsNativeFeeSwap` deploys the real v4 PoolManager and an original-body hook, supplies liquidity, then verifies the failed native-fee swap and unchanged trader balances. This is a configuration-dependent denial of service, not theft. A normal ETH-capable beneficiary does not exhibit it. A quote token that refuses transfers to the beneficiary can cause the analogous original push-payment failure.

**Repair:** `_afterSwap` mints PoolManager claims to the hook and returns the matching positive delta. The beneficiary subsequently calls `collectFees`; claims are burned before transferring underlying currency. A failed payment rolls back the burn. The immutable beneficiary can select a receiving address it controls. No fee value, currency choice or economic entitlement changes; **payout timing and API do change from immediate transfer to explicit collection**.

**Regression coverage:** rejecting beneficiary with successful swaps; rejected collection preserving claims; retry to a valid destination; partial collection; overcollection and double collection; unauthorized collection; reentrant collection blocked by the active-collection guard. Real manager tests verify that returned deltas settle the claim mint exactly. Reference: the pinned [`PoolManager.mint/burn/take`](lib/v4-core/src/PoolManager.sol) and [`ERC6909Claims`](lib/v4-core/src/ERC6909Claims.sol).

### SIMD-02 — supply parameter does not enforce the launch amount

**Trigger:** `new SuperIMD(1000000000, recipient)` in the original succeeds, creating `10**9` base units, or `10**-9` whole tokens with the inherited 18 decimals. It also accepts zero or any other supply. The original is fixed *after construction*, but it does not enforce the requested launch amount. This is a deployment validation issue, not an unauthorized post-deployment mint.

**Evidence:** `test_regressionOriginalAllowsWrongSupply` demonstrates the raw-unit mistake. The repaired constructor keeps the same ABI but rejects all values except `INITIAL_SUPPLY = 1_000_000_000 * 10**18`. Fuzz tests check other supplies and normal transfer conservation; a zero recipient is rejected by OpenZeppelin `_mint`.

**Tradeoff:** deployment configuration must use base units. There is no whole-token conversion at runtime. [OpenZeppelin ERC20 documentation](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20) explains the inherited 18-decimal default; the exact vendored version is recorded in `DEPENDENCIES.json`.

### SIMD-03 — project-token restriction is absent

**Trigger:** initialize a sorted native/other-token pool using the original hook, where neither currency is the immutable `projectToken`, and execute a swap. The original body selects a fee currency and charges it without checking membership. This contradicts a project-specific interpretation of the hook; the unused immutable does not limit pool use. It does **not** let an arbitrary caller impersonate PoolManager, nor does it tax pools which did not select this hook.

**Evidence:** `test_regressionOriginalChargesUnrelatedPool` demonstrates the original callback charging two units for a 100-unit unrelated-token output. The repair checks the hook field, currency ordering and exact project-token membership. Real-manager `test_unrelatedPoolCannotSwapThroughHook` confirms a rejected swap and successful LP principal removal afterward.

**Limit:** the existing permissions enable only `afterSwap`. An unrelated pool can still initialize and accept liquidity, but cannot swap using this hook. Check the pool key before funding. The quote side is deliberately not an allowlist: this implementation supports standard token quotes and does not infer IMD identity from a symbol. Initialization permission changes or a quote allowlist would be a separate design change.

### SIMD-04 — signed absolute-value boundary

**Trigger:** a manager-authenticated exact-output callback carries an unspecified amount of `-2**127`. The expression `unspecifiedAmount = -unspecifiedAmount` attempts to represent `2**127` as `int128`, causing Solidity panic `0x11` before fee calculation.

**Evidence:** `test_regressionOriginalMinInt128Panics` proves this with the accounting mock. `test_minInt128ArithmeticDoesNotPanic` verifies the repaired magnitude calculation, and fuzz cases cover representable magnitudes and all four swap modes. The widened magnitude is at most `2**127`; multiplying by 200 cannot overflow `uint256`, and the 2% fee fits positive `int128`.

**Severity limit:** this is not demonstrated as a valid full-swap availability failure. Even after safe absolute-value arithmetic, subtracting a positive fee from an already minimum `int128` input would exceed v4's final `BalanceDelta` range and revert. The project supply is also far below this magnitude. The repair makes isolated arithmetic robust; it does not promise that extreme final deltas can settle. The final range is checked by the pinned [`BalanceDelta` subtraction](lib/v4-core/src/types/BalanceDelta.sol).

### SIMD-05 — reproducible hook deployment and authentication

Uniswap chooses which callbacks to invoke from the hook address's low bits, not by calling `getHookPermissions()`. The required combination is `(address & 0x3fff) == 0x0044`. A random deployment address may omit the fee callback, omit its returned delta, or enable callbacks that this hook does not implement. See the pinned [`Hooks.validateHookPermissions`](lib/v4-core/src/libraries/Hooks.sol) and [Uniswap's hook source](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol).

The supplied base was absent, so its validation and callback authentication could not be assessed. The added base stores a nonzero immutable manager, validates all permission bits in construction, restricts every hook callback to that manager, and reverts disabled callbacks. The collection callback additionally requires an active authorized collection.

The ordinary launch factory does not mine hook salts. The launchable `SuperIMDHookFactory` therefore deploys the child after its explicit owner selects a real PoolManager and supplies a locally mined salt. Ownership is a constructor argument; it never derives from `msg.sender` or `tx.origin`. Manager selection is changeable only before deployment and emits an event. No manager address is invented. Code checks occur on first operational use, not in application constructors.

Tests cover missing configuration, every invalid constructor address, unauthorized setters/deployment, correction before deployment, invalid salt, exact prediction versus actual CREATE2 deployment, no dependency code at application construction, dependency-code failure at child deployment, frozen configuration, all disabled callbacks and opcode/runtime limits. The salt utility is tested through its actual `run` entry point.

## Behavior confirmed rather than changed

The original fee-currency expression agrees with v4's mapping of the unspecified delta. Returning a positive delta charges the swapper: exact-input output decreases and exact-output input increases. Both token orderings and both swap directions are tested against otherwise identical no-hook pools. No claim is made that a 2% fee is always taken in ETH/IMD, that total price impact is 2%, or that LP/protocol fees are included. [Uniswap custom accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting) describes the two modes.

The supplied ERC20/ERC20Permit pattern has no exposed mint or tax override. The delivered token retains standard OpenZeppelin permit handling. Tests cover relayed use, replay, wrong nonce/value, expiration and equality at the deadline, malformed signature, zero spender, cross-contract and cross-chain reuse, and fee-free allowance spending. Permit conveys an allowance; integrations must not treat it as a signed swap instruction. Contract-wallet holders can use ordinary approval; ERC-1271 permit support was not added.

There are no arbitrary external calls or delegatecalls in the application API. The hook cannot initiate swaps, so v4's `msg.sender == hook` self-call exemption cannot be reached through a hook swap entry point. Collection burns only the hook's own claims, for a destination selected by the fixed beneficiary, and the manager lock plus the hook's collection guard prevent nested withdrawal. The factory cannot change an existing hook.

## Assumptions and residual risks

- **Trusted manager selection:** the factory checks nonzero deployed code, not protocol identity. The owner must verify the manager on the intended chain before deployment. A malicious manager invalidates the accounting and authentication assumptions. No compatible manager deployment on chain 4663 was verified in this assignment.
- **Immutable beneficiary and owner:** no rotation, recovery, pause, rescue or upgrade path exists. The owner can activate the factory once; the beneficiary controls claim redemption. Beneficiary-key loss strands uncollected fees. Correct constructor values and wallet control must be checked before launch.
- **Supported currencies:** local tests use native ETH, SIMD and ordinary ERC-20 quote tokens. Fee-on-transfer/rebasing tokens and malicious token contracts are not supported by the stated accounting assumptions. Freezes or blacklists in a quote token can still stop settlement/collection; pull collection only removes the fee-recipient call from swaps.
- **Pool and router responsibilities:** initialize the intended key and price, provide real liquidity, and enforce trader deadlines, exact-output completeness and final slippage. A publicly initialized pool can start at a price chosen by its initializer; this hook does not reserve initialization. No router or pool is a launch application.
- **Scope of fee:** voluntary pool selection, base-unit rounding and partial execution remain as described in the README. Splitting into dust-sized swaps can reduce rounded fees. The fixed rate provides no anti-sandwich, anti-sniper or external-venue enforcement.
- **Collection operations:** call outside another unlock and use a compatible receiving destination. Failed collection is atomic. Direct transfers to the hook have no rescue path. Extra PoolManager claims transferred to the hook belong to its fixed beneficiary.
- **Deployment artifact stability:** CREATE2 depends on exact bytecode, arguments, factory and salt. The pinned compiler/settings and init-code hash must match the launch build; formatting source with metadata hash disabled does not provide permission to change code or compiler configuration.

## Verification record

Meaningful local checks include token and hook unit tests, original-code regressions, actual v4 PoolManager integration tests, factory/script tests, and stateful fee/conservation invariants. The requested fuzz seed is pinned in `foundry.toml`. Invariant runs execute random buy/sell, exact-input/output and partial fee-collection sequences; every supported action must succeed, every manager unlock must leave zero transient debt, and accrued claims plus collections must equal modeled fees.

The protected input tests depend on launch-stage environment and manifest data, so they are not copied into the delivered test directory or supplied fake launch values. The local factory tests independently exercise the same relevant runtime-size/opcode and explicit-owner properties. The final launch-stage verifier remains responsible for the resolved deployment values.

`forge build`, `forge test` and `forge fmt --check` are the required reproducibility checks. See [VALIDATION.md](VALIDATION.md) for their final local results. Slither, Mythril, formal verification, a live fork and an independent human/contributor review were not performed. Compiler/linter observations about safe casts, packed CREATE2 preimages, trusted-manager calls and guard resets are reviewed as such; they are not evidence of an exploit by themselves.
