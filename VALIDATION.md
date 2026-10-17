# Local validation

Validated on 2026-10-17 with the project's pinned Solidity 0.8.26 configuration. These are local implementation checks, not independent approval or verification of any deployed chain address.

| Command | Result |
| --- | --- |
| `forge build` | Passed; compiler successful |
| `forge test` | Passed; 55 test entries across five suites, zero failures or skips |
| `forge test --threads 4` | Passed; same 55 entries with parallel execution |
| `forge fmt --check` | Passed |

The 55 reported entries comprise 54 unit/integration test functions and one grouped stateful suite containing two invariant properties. The properties cover currency conservation/settled debts and equality of earned fees to claims plus collections. The invariant suite completed 64 sequences, 2,048 calls (1,027 swaps and 1,021 collection actions), with zero reverts. Each fuzz test ran 256 cases. All runs used the seed pinned in `foundry.toml`:

```text
0x8a3267c8614af88603dbe755eb3c5533c31ba131827f70ffb66e56b147023017
```

| Artifact | Creation code bytes, excluding arguments | Runtime bytes |
| --- | ---: | ---: |
| `SuperIMD` | 5,248 | 3,742 |
| `SuperIMDHook` | 6,035 | 5,138 |
| `SuperIMDHookFactory` | 8,201 | 7,862 |

All three artifacts have no external library link references. Tests check deployed runtime size against EIP-170 and scan executable opcodes for the launch's forbidden `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`. They also check init-code bounds, explicit beneficiary/owner assignment through a deploying contract, and application construction without external dependency code.

The successful build retains these Forge lint observations; none is hidden by a global lint disable:

- **Unsigned magnitude cast:** the input was widened from `int128`; its nonnegative magnitude is at most `2**127`, making the conversion safe. Boundary and fuzz tests cover the arithmetic.
- **Collection guard reset after external call:** `collecting` is set before unlock and remains active throughout the callback and receiver transfer. It resets after success; a revert restores it atomically. Reentrant withdrawal and failed-transfer/retry tests cover both paths.
- **Unused unlock return:** the authenticated callback intentionally returns empty bytes; accounting is validated by PoolManager's zero-debt requirement, not callback return content.
- **Events after calls:** claim minting in the pinned manager does not call recipients, and the known hook constructor does not call external contracts. The collection event is emitted after successful redemption; no safety invariant relies on its order relative to unrelated receiver activity.

The protected launch-stage tests were read but require later manifest/resolved-deployment data; they were not run with invented environment values. Live fork testing, target-chain address verification, Slither, Mythril, formal verification and independent contributor review were not performed. Activation and deployment responsibilities are documented in [README.md](README.md); concrete original-code findings and their limits are in [AUDIT.md](AUDIT.md).
