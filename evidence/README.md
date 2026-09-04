**Saved verification results**

The run recorded on 2 September 2026 at 15:58:06 UTC matched all 14 listed
contract addresses on Arc mainnet (5042). No installation is needed to read
these results.

On 3 September 2026 at 21:44:24 UTC, the packaged sources were recompiled
offline. All 14 creation and runtime bytecodes matched both saved RPC
responses. No new chain request was made during that revalidation.

| Contract | Result | RPC runtime matches |
|---|---|---|
| TollyToken | MATCH | 2/2 |
| TollyPad | MATCH | 2/2 |
| TollyFeeLocker | MATCH | 2/2 |
| TollyFurnace | MATCH | 2/2 |
| TollyHolderVault | MATCH | 2/2 |
| TollyTreasury | MATCH | 2/2 |
| TollyLens | MATCH | 2/2 |
| TollyForgeDeployer | MATCH | 2/2 |
| TollyUniversalForge | MATCH | 2/2 |
| TollyRouterForge | MATCH | 2/2 |
| TollyLiquidityForgeFactory | MATCH | 2/2 |
| TollySwapRouter | MATCH | 2/2 |
| TollyMultiRouter | MATCH | 2/2 |
| TollyBurner | MATCH | 2/2 |

The two endpoints were `arc-scan` and `tolly-relay`. Their agreement does not
prove that they use independently operated infrastructure. All recorded
immutable comparisons passed. For 11 direct deployments, creation transaction
inputs also matched the compiled creation bytecode and constructor arguments.
For TollyToken, TollyFeeLocker and TollyBurner, only the parent transaction and
runtime immutables were checked, not the full internal creation calldata.

The [full JSON report](latest.json) contains the deployed bytecode, RPC
responses, compiler settings, hashes and individual results. If GitHub cannot
preview it, [open the raw JSON](https://raw.githubusercontent.com/TollyLabs/v3-contracts/main/evidence/latest.json).
Addresses and expected values are in the [deployment manifest](../deployment/arc-mainnet-5042.json).

This summary describes the bundled RPC capture and its offline revalidation,
not current chain state or a security audit. Running the verifier replaces
`latest.json` but does not update this summary. The current report's SHA-256 is:

```text
cef356a9a9454bd1466c1622114306d61ecc77742dc5872b3d6f887c4d6dc624
```

To perform your own comparison, follow the [verification instructions](../README.md).
