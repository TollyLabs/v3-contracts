Licensing is assigned per file. There is no single license for every Solidity
source in this repository.

The following TollyLabs files use the
[Business Source License 1.1](LICENSES/BUSL-1.1.txt):

- `contracts/TollyForge.sol`, except its `FullMath` library
- `contracts/TollySwapRouter.sol`
- `contracts/TollyMultiRouter.sol`
- `contracts/launchpad/TollyFeeLocker.sol`
- `contracts/launchpad/TollyHolderVault.sol`
- `contracts/launchpad/TollyTreasury.sol`

BUSL permits copying, modification, redistribution and non-production use. It
does not permit production use before the Change Date unless TollyLabs grants
separate permission. On 3 September 2028, these portions convert to
GPL-2.0-or-later. BUSL is source-available, not an open-source license before
that date.

This assignment applies to this version of the affected files. It does not
revoke permissions that a recipient may already have received for an earlier
copy under another license.

The following files use
[GPL-2.0-or-later](LICENSES/GPL-2.0-or-later.txt):

- `contracts/launchpad/TollyPad.sol`
- `contracts/launchpad/libraries/TickMath.sol`

`TickMath.sol` is derived from Uniswap v3-core. Its GPL license and attribution
are preserved. `TollyPad.sol` imports that library and also compiles the
creation bytecode of `TollyToken` and `TollyFeeLocker`. The GPL terms covering
Pad and TickMath are preserved. The separate TollyFeeLocker source remains a
TollyLabs BUSL Licensed Work; this repository does not claim ownership of or
relicense any Uniswap-derived code.

The following files and portions use [MIT](LICENSES/MIT.txt):

- `contracts/TollyLens.sol`
- `contracts/launchpad/TollyToken.sol`
- the `FullMath` library inside `contracts/TollyForge.sol`
- the verifier, shell helper, manifests and repository documentation written
  by TollyLabs, unless a file states otherwise

The MIT status of TollyToken and the BUSL status claimed for the separate
TollyFeeLocker source do not remove any GPL obligations that may apply when
they are distributed or compiled as part of TollyPad. This notice describes
the intended licensing boundary; it is not legal advice or a ruling on whether
particular uses form a derivative work.

OpenZeppelin is an external MIT-licensed dependency installed through pnpm and
is not relicensed by TollyLabs. See [NOTICE.md](NOTICE.md) for third-party
attribution. Each dependency retains its own license and notices.
