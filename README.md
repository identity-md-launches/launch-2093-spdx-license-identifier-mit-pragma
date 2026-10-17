# Super IMD — audited implementation

This Foundry project implements the supplied Super IMD token and Uniswap v4 fee hook, with repairs and executable reproductions of the review findings. See [AUDIT.md](AUDIT.md) for the evidence, severity and remaining assumptions.

- **Token:** Super IMD (`SIMD`), 18 decimals, exactly **1,000,000,000 whole tokens** (`1000000000000000000000000000` base units).
- **Supply:** minted once to the explicit constructor recipient. No public mint, burn, ownership, pause, blacklist, proxy or transfer tax.
- **Permit:** OpenZeppelin ERC-2612, name `Super IMD`, version `1`, with chain/contract domain separation, nonce and deadline checks. Ordinary approval remains available.
- **Hook:** an immutable 200 basis point fee, rounded down, in pools containing `projectToken`. Native ETH and standard ERC-20 quotes, including a verified IMD token, are supported.
- **Website / X:** https://www.si-md.xyz/ and https://x.com/SuperIMD_eth (provided project links).

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer runs **200**, and `bytecode_hash = "none"`. It pins the requested fuzz seed `0x8a3267c8614af88603dbe755eb3c5533c31ba131827f70ffb66e56b147023017`. Fuzz tests use 256 cases; stateful invariants use 64 sequences of depth 32. Tests require no RPC, fork, environment configuration, file permissions, FFI, signer or network. The compiler and Foundry are the verification runtime; Solidity dependencies are ordinary files under `lib/`.

| Component | Location | Purpose |
| --- | --- | --- |
| `SuperIMD` | `src/SuperIMD.sol` | Fixed-supply ERC-20 with permit |
| `SuperIMDHook` | `src/SIMDhook.sol` | Swap fee accounting and collection |
| `BaseHook` | `src/base/BaseHook.sol` | Manager authentication, address validation, disabled callbacks |
| `SuperIMDHookFactory` | `src/SuperIMDHookFactory.sol` | Owner configuration and one mined CREATE2 hook deployment |
| `MineHookSalt` | `script/MineHookSalt.s.sol` | Pure offline salt search; no broadcast or environment access |
| Original-code fixtures | `test/helpers/HookFixtures.sol` | Reproduce issues in the submitted bodies |
| Unit, integration and invariant tests | `test/` | Token, fee, deployment, settlement and adversarial behavior |

Dependency repositories and full commit hashes are recorded in [DEPENDENCIES.json](DEPENDENCIES.json). OpenZeppelin Contracts is v5.1.0; forge-std is v1.9.7. Uniswap v4-core is pinned at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`, including the `PoolOperation.sol` API used by the brief. No dependency is a submodule. Licenses remain alongside the vendored sources. The actual PoolManager is deployed **only in local tests**, not as a launch application.

## Precisely what the fee means

The fee is `floor(abs(unspecifiedCurrencyDelta) * 200 / 10000)` on the actual executed swap amounts. Currency selection follows Uniswap's return-delta semantics. See [Uniswap custom accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting) and the vendored [`Hooks.afterSwap`](lib/v4-core/src/libraries/Hooks.sol).

| Swap mode | Unspecified currency | Effect on trader |
| --- | --- | --- |
| Exact input (`amountSpecified < 0`) | Output currency | Receives gross output minus the fee |
| Exact output (`amountSpecified > 0`) | Input currency | Pays gross input plus the fee |

For both directions, exact input preserves the input delta and exact output preserves the output delta. Thus a gross output of 1,000 units becomes 980 units, while a gross input of 1,000 units becomes 1,020 units. The exact-output fee is 2% of **pre-hook input**, approximately 1.9608% of total input paid. It is not a quote-token-only tax: an ETH-to-SIMD exact-input buy accrues SIMD, while a SIMD-to-ETH exact-input sell accrues ETH. Exact-output uses the opposite side.

Fees below one base unit round to zero: a magnitude below 50 base units incurs no hook fee. Rounding favors traders, and splitting swaps can reduce rounded fees. This preserves the supplied formula; there is no minimum fee. A price limit can partially fill a swap, including exact output; the hook charges only the executed amount. Routers must enforce required output and maximum input **after** the hook adjustment. LP and protocol fees remain additional PoolManager fees.

There is no time-varying antisniper fee, transfer fee, exemptions, owner fee setter or launch trading gate. The reference to “sell antisniper” in the original token comment does not describe implemented behavior. Pools using other hooks, other DEXs and direct transfers do not pay this hook's fee. The token does not force a particular trading venue.

## Fee collection

During swaps the hook calls `PoolManager.mint` to retain fee claims under its own address. It returns the matching positive hook delta, so PoolManager's transient debit is settled in the same swap. Neither the fee recipient nor an ERC-20 transfer callback runs during fee accrual. The underlying currency remains in PoolManager as backing for the claims.

The immutable `feeRecipient` alone can call:

```solidity
hook.accruedFees(currency);
hook.collectFees(currency, amount, recipient);
```

`collectFees` burns claims and transfers the corresponding currency to the beneficiary's chosen nonzero destination. A smart-wallet beneficiary that rejects ETH can choose an ETH-capable destination. Zero amounts and the hook itself as destination are rejected. Collect outside any other PoolManager unlock; nested collection is rejected. Failed transfers, overcollection or callback failures revert the whole withdrawal, retaining the claims for a retry. There is no operator approval to grant and no separate initialization of collection.

Withdrawals may be partial. Each withdrawal must fit PoolManager's positive `int128` amount limit; very large aggregate balances can be collected in tranches. `FeeAccrued(poolId,currency,amount)` and `FeesCollected(currency,recipient,amount)` support accounting. Fees across supported pools aggregate by currency; the accrual event identifies their pool of origin.

Directly sending native currency, ERC-20s or unrelated assets to the hook is not fee collection. The hook has no general rescue function. Do not send funds to it outside the documented manager accounting flow. Anyone can transfer PoolManager claims to the hook; those claims become collectible by the fixed beneficiary.

## Deployment handoff

The launch target specified by the assignment is chain **4663**. No on-chain addresses have been deployed or verified by this assignment. There was no supplied PoolManager or IMD quote-token address for that chain. Do not copy addresses from another chain.

The launch applications are **`SuperIMD` followed by `SuperIMDHookFactory`**. Deploying `SuperIMDHook` directly through the ordinary launch factory is unsuitable because its salts are not mined for v4's permission bits. The hook factory is the application that later creates the hook. No pool, distributor, extra launch token or `launch.json` is included.

| Application constructor | Argument | Launch value / meaning |
| --- | --- | --- |
| `SuperIMD(uint256,address)` | `initialSupply` | `1000000000000000000000000000`; any other value reverts |
| | `recipient` | `$owner`, the launch beneficiary; receives the full supply |
| `SuperIMDHookFactory(address,address,address)` | `owner_` | `$owner`, explicitly passed; never the deploying factory or transaction origin |
| | `feeRecipient_` | `$owner`, the fee beneficiary under the launch policy |
| | `projectToken_` | `$contract:SuperIMD`, the previously deployed token |

`$owner` and `$contract:SuperIMD` above are manifest-step references, not literal addresses or Solidity defaults. The launch service resolves them. All constructor arguments are static and nonpayable. The application constructors make no external contract calls and do not require dependencies to have code. Tests rehearse construction through a separate deploying contract and check bytecode size and forbidden opcodes.

The hook factory starts **unconfigured**, not pointed at a substitute manager. `hookInitCodeHash`, prediction and deployment revert `NotConfigured()` until a manager is set. The token and factory are usable deployment artifacts even before this external dependency is selected. There is no live trading pool at that stage.

### After launch

1. **Verify the dependency and execution environment.** The owner obtains the intended chain's canonical v4 PoolManager from the protocol's official deployment records and checks its code and implementation against this integration. Confirm Cancun/transient-storage support on the target chain. A nonempty code check proves only that a contract exists; it does not authenticate PoolManager. If no compatible manager exists on chain 4663, do not activate a pool.
2. **Configure the manager.** The explicit owner calls `SuperIMDHookFactory.setPoolManager(manager)`. It rejects zero and code-less addresses and emits `PoolManagerConfigured(previousManager,manager)`. The owner may correct this setting **before** hook deployment. Every dependent deployment path fails clearly while unset. The factory exposes no automatic discovery or guessed address.
3. **Read and mine.** Obtain `hookInitCodeHash()` from the configured factory. Run the offline utility with the actual deployed factory address and returned hash, a starting nonce and a bounded number of attempts. For example, the command shape is:

   ```text
   forge script script/MineHookSalt.s.sol:MineHookSalt --sig 'run(address,bytes32,uint256,uint256)' ACTUAL_FACTORY ACTUAL_INIT_CODE_HASH 0 200000
   ```

   Replace the two argument labels with the real values. This utility performs no RPC requests, environment reads or transactions. If its search is exhausted, continue at the next nonce range. The salt is public and is not a signing key. The address must satisfy `(uint160(address) & 0x3fff) == 0x0044`: only `afterSwap` and `afterSwapReturnDelta`. Re-read the hash if the manager changes. Any compiler, constructor, code or deployer change requires new prediction/mining.
4. **Deploy the hook.** Compare the utility's prediction with `factory.predictHookAddress(salt)`. The owner calls `deployHook(salt)` through their normal wallet workflow. The factory rechecks manager/token code, checks all 14 permission bits, deploys once, records `hook`, and emits `HookDeployed`. Its PoolManager setting is frozen thereafter. Confirm the hook's manager, token, beneficiary, fee constants and runtime code. This assignment does not sign or broadcast that operation.
5. **Create and fund the intended pool through the chosen v4 tooling.** Pool creation and liquidity management are operator responsibilities. Sort the two currencies numerically, use native `Currency.wrap(address(0))` for ETH or the independently verified IMD quote address for IMD, and use the emitted hook address. Confirm the quote's decimals and standard transfer behavior. The pool's LP fee, tick spacing, initial price, amount/range of liquidity and router are operator pool-creation parameters; this project neither guesses nor creates them. The 2% hook rate is independent of those choices.
6. **Operate fee collection and trading.** Integrate quotes/slippage using the final returned deltas, publish the actual pool key and addresses, and collect accrued fees using the immutable beneficiary account. Protect that account and the factory owner's account. Obtain an independent adversarial review before using the contracts with external funds.

Only the manager is an owner-settable dependency. The IMD quote address is part of the chosen `PoolKey`, not a stored configuration value; the hook deliberately does not claim to authenticate the IMD symbol. A sorted pool must contain the exact `projectToken` address. Unsupported pools may be initialized because no initialization hook is enabled, but swaps revert and liquidity can be removed.

The factory owner can choose/correct the manager and deploy its single hook. That role is immutable and has no recovery or transfer function. After deployment it has no authority over the hook. The beneficiary can collect claims and choose their payout destination but cannot change the beneficiary role, manager, token or fee rate. Neither token nor hook is upgradeable. Losing beneficiary control makes uncollected fees inaccessible; losing factory-owner control before deployment prevents activation.

## Validation scope

The suite compares real hooked pools against matching pools with no hook, checks actual payer/manager balance changes, and asserts zero transient debts after each unlock. It covers ETH and mock standard IMD quotes, both SIMD address orderings, all four swap modes, LP fees, partial/empty fills, fee rounding, collection rollback/reentrancy, direct callback attacks, supply and ERC-2612 failures, mined address deployment and explicit ownership. Stateful invariants check currency conservation and `earned fees = outstanding claims + collected fees`.

These are local tests of pinned source, not a fork test or chain deployment certification. Nonstandard quote tokens (fee-on-transfer, rebasing, malicious callbacks or administrative freezes), arbitrary routers, live liquidity and the target chain's manager remain outside the verified integration assumptions. See the audit for the limits of the original arithmetic reproduction and the unknown original BaseHook.
