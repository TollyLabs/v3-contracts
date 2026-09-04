**Tolly V3 on Arc**

This repository contains the source code and bytecode verification results for
14 contract addresses on Arc mainnet (chain ID 5042). Several contracts share a
source file. The verifier compiles the sources locally and compares the result
with the deployed code returned by two RPC providers.

This is a source and verification release, not a security audit. Running the
check does not deploy anything or submit contracts to an explorer.

**Licensing**

Licensing is assigned per file. Independent TollyLabs infrastructure in Forge,
the routers, FeeLocker, HolderVault and Treasury uses BUSL-1.1 until 3 September
2028, then converts to GPL-2.0-or-later. Pad and TickMath remain
GPL-2.0-or-later; Lens, Token, FullMath and the verification tools remain MIT.

BUSL permits inspection, modification and non-production use, but does not
permit deploying the protected code in production before the Change Date
without separate permission from TollyLabs. Interfaces can still call the
official deployed contracts. Read [the complete per-file boundary](LICENSE.md)
and [third-party notices](NOTICE.md) before reusing the source.

These terms apply to this version. See [LICENSE.md](LICENSE.md) for the exact
file-level boundary.

**View the saved results. No installation needed.**

Open [the saved results](evidence/README.md) without installing or running
anything. The [full JSON report](evidence/latest.json) is also included; use
[the raw version](https://raw.githubusercontent.com/TollyLabs/v3-contracts/main/evidence/latest.json)
if GitHub does not display the large file. The check recorded on 2 September 2026
at 15:58 UTC returned `MATCH` for all 14 contracts using two RPC providers.
The report includes the deployed bytecode returned by each provider, compiled
runtime hashes, and the comparison results for each contract.

This is a saved record, not a fresh check or a security audit. To independently
check the sources against the deployed code, follow the instructions below.

**Run your own verification (optional)**

You need Node.js 24 LTS, pnpm 10.33.4, and an internet connection. No wallet,
private key, API key, or gas payment is needed. If Node.js and pnpm are already
installed, skip the setup for your system.

Download and extract the complete package. On GitHub, use **Code > Download ZIP**.
Run the commands from the folder containing `package.json`, without editing
the sources or `pnpm-lock.yaml`.

Windows

Install Node.js 24 LTS from [nodejs.org](https://nodejs.org/en/download) using
the Windows installer with PATH enabled. Install pnpm in PowerShell:

```powershell
$env:PNPM_VERSION = "10.33.4"; Invoke-WebRequest https://get.pnpm.io/install.ps1 -UseBasicParsing | Invoke-Expression
```

This runs the [official pnpm installer](https://pnpm.io/10.x/installation).
Once installed, close PowerShell, open the project folder in File Explorer,
type `cmd` in the address bar, and press Enter.

macOS

Install Node.js 24 LTS with the macOS installer from
[nodejs.org](https://nodejs.org/en/download). In Terminal, install pnpm:

```sh
curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=10.33.4 sh -
```

Open a new Terminal window. Type `cd` followed by a space, drag the extracted
project folder into the window, and press Return.

Ubuntu

Install Node.js through [nvm](https://github.com/nvm-sh/nvm#installing-and-updating)
if it is not already available:

```sh
sudo apt update
sudo apt install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash
```

Close and reopen Terminal, then install Node.js and pnpm:

```sh
nvm install 24
nvm use 24
curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=10.33.4 sh -
```

Open a new terminal in the extracted project folder using **Open in Terminal**
in Files, or navigate there with `cd`.

The pnpm installers update your shell configuration. If your system blocks
an installer, use an alternative from the official installation guide rather
than disabling antivirus or other security controls.

From the project folder

Check the installed versions:

```sh
node --version
pnpm --version
```

They should report Node.js `v24.x.x` and pnpm `10.33.4`. Then run:

```sh
pnpm install --frozen-lockfile --ignore-scripts && pnpm run verify
```

The same command works in Windows Command Prompt, macOS Terminal, and Ubuntu.
It uses the locked dependencies and disables installation scripts. Verification
starts only if installation succeeds. Do not run it as administrator or with
`sudo`.

Compilation can take several minutes without printing anything. Once dependencies
are installed, subsequent checks only need `pnpm run verify`. On macOS and
Ubuntu, `bash ./verify.sh` also installs missing dependencies and runs the check.

**Reading the result**

A successful run ends with:

```text
RESULT MATCH 14/14 contracts; evidence=
```

The rest of that line is the path to `evidence/latest.json`, which contains the
responses, results, and a UTC `capturedAt` timestamp.

A `MISMATCH`, `RPC ERROR`, crash, or missing final success line means the full
check did not pass. A provider outage can prevent verification without proving
that the contracts differ. Read the error before drawing that conclusion.

The included report records an earlier run. A new comparison replaces it,
including on a mismatch; a failure before comparison may leave it untouched.
Check the timestamp as well as the terminal output, and copy the report elsewhere
before rerunning if you want to keep it.

If something fails, the usual checks are:

- If Node.js or pnpm is not found, reopen the terminal after installation.
  On Ubuntu with nvm, select Node.js with `nvm use 24`.
- If PowerShell blocks `pnpm.ps1`, use Command Prompt. Do not disable execution
  policies.
- If `package.json` or a dependency is missing, check the current folder and
  repeat the installation command using the original lockfile.
- For permission errors, use a folder you own, such as Downloads or Documents.
  Do not use `sudo pnpm`.
- For RPC timeouts or HTTP 429/503, wait for the provider to recover. Do not run
  repeated retries, scheduled checks, or CI jobs against these endpoints.
- For a source hash, compiler, or bytecode mismatch, keep the error and report.
  Do not change the manifest or dependencies to force a match.

For help, include your OS, Node.js/pnpm versions, the error text, and the report
timestamp. Do not share credentials or private keys.

**What is being compared**

The build uses solc `0.8.26+commit.8a97fa7a.Emscripten.clang`, OpenZeppelin
`5.6.1`, optimizer 200, via-IR, Cancun, and `bytecodeHash = none`. Dependency
versions and archive hashes are fixed in `pnpm-lock.yaml`. The verifier also
checks each bundled source against its SHA-256 in
`deployment/arc-mainnet-5042.json`.

Both providers must report chain 5042 and return the same non-empty runtime
for every listed address. The verifier isolates only the immutable ranges
identified by the compiler, compares the remaining bytecode, then checks every
immutable separately against the manifest. It sends one batch to each provider,
with a 30-second timeout and no automatic retry.

For the 11 direct deployments, it also compares the creation transaction input
with the compiled creation bytecode and encoded constructor arguments.

Three contracts were created internally: the FeeLocker by the Pad constructor,
TollyToken through `TollyPad.createToken`, and the listed TollyBurner through
TollyUniversalForge. Standard transaction lookup does not expose their internal
creation calldata. Their runtime and immutables are checked, along with the
parent transaction's chain, destination, and full input hash on both providers.
That is why their output reads `constructor=parent=2/2;immutables-only`; it is
not a full internal-constructor proof.

A failed check returns a nonzero exit code.

**Contracts**

| Contract | Arc address | Source |
|---|---|---|
| TollyToken | `0xbc43ce8dec648ea298c4275559b81d6261c90b67` | `contracts/launchpad/TollyToken.sol` |
| TollyPad | `0xcad7ee36ac193bf2eddb7b3e2736c5bdb8269c8b` | `contracts/launchpad/TollyPad.sol` |
| TollyFeeLocker | `0xe20e4297759597da75c8998ee76ec900600ad920` | `contracts/launchpad/TollyFeeLocker.sol` |
| TollyFurnace | `0xe60483df8bb33dbe7c50c47b440e957eb65614c3` | `contracts/TollyForge.sol` |
| TollyHolderVault | `0x150bf8f4087d50da1081365e4a28d7912045a8f4` | `contracts/launchpad/TollyHolderVault.sol` |
| TollyTreasury | `0xa00c3a33bcb68856f9fd86003e17f76a733fc355` | `contracts/launchpad/TollyTreasury.sol` |
| TollyLens | `0xcb249e9613123ad57dc438d5393e471c00020959` | `contracts/TollyLens.sol` |
| TollyForgeDeployer | `0x04b8a7aeafce846acd3838ad5961787810339db1` | `contracts/TollyForge.sol` |
| TollyUniversalForge | `0x6619d00e448664ac900f1f512a5b65e8ac358a7b` | `contracts/TollyForge.sol` |
| TollyRouterForge | `0xb808e78846205905607a425b329f0bcf8e036fab` | `contracts/TollyForge.sol` |
| TollyLiquidityForgeFactory | `0xd988b525960bf069cd2ef869642b8c2a26065cc0` | `contracts/TollyForge.sol` |
| TollySwapRouter | `0xcebc2e409a85cfa82b086674e6bc5bed51692777` | `contracts/TollySwapRouter.sol` |
| TollyMultiRouter | `0xf28c138a39c234554c847dbef467b073ddbd7451` | `contracts/TollyMultiRouter.sol` |
| TOLLY TollyBurner instance | `0x41bd155c88148f29081901809ac04d34b5e66b1d` | `contracts/TollyForge.sol` |

`TollyForge.sol` is kept unchanged because the verified factory runtimes embed
creation bytecode for other tools defined in that file. Removing those definitions
would change the factories' bytecode. Only the six targets from that file listed
above are claimed to match; other factory-created instances are outside this check.

V4, protected-order executors, airdrop and rewards code, testnet contracts,
simulations, deployment scripts, and future refactors are not part of this package.
See [the license notices](LICENSE.md) for the license assigned to each file.

**Notes on the original source comments**

Other than license and attribution notices, the source files are preserved as
recorded in the original verification. Some comments describe earlier designs: `TickMath`
mentions Solidity 0.8.24, but this build uses 0.8.26. Older Forge comments refer
to permanent tool liquidity locks; `TollyLiquidityForge` supports time locks
and withdrawal after `unlockTime`, as well as permanent locks. That tool is not
one of the 14 verified addresses. The Pad's separate FeeLocker has no LP
withdrawal path.

The name `weth` in Forge is historical. For the listed Arc deployments, the
manifest identifies the quote asset as USDC. Source comments about other
deployments are not evidence of their current status.

**Permissions**

Matching the code does not remove the powers written into it:

- The Pad owner can update the name/symbol ban list for future launches and
  transfer ownership. This does not let them change existing tokens, pool
  parameters, LP custody, or the fee split.
- The Treasury owner can withdraw Treasury assets and transfer ownership
  through the two-step ownership flow.
- The HolderVault's immutable setter can assign a nonzero distributor and a
  nonzero locker, each once. The locker can record accruals.
  The distributor can record accruals and release funds against per-project
  balances. Recording an accrual does not prove a matching transfer happened;
  a faulty or malicious distributor can corrupt the shared accounting.
- Launch creators can redirect or claim their own 64% share through the
  FeeLocker's `setPayout` and `claim` functions.
- Forge-created tools have instance-specific owner powers, but no control over
  Pad LP NFTs.
- Collection and burn triggers are permissionless, but someone still needs to
  submit the transactions.

The bundled verifier does not query current owners or mutable role assignments.
Earlier internal observations of those roles are not included in this report
and should not be treated as current-state evidence.

**Limits of this check**

A match establishes code identity within the scope above. It does not establish
that the contracts are bug-free, economically safe, independently audited, or
verified by Arc Scan.

The check relies on honest RPC responses, Arc consensus, the third-party
Uniswap contracts, and the integrity of the build tools and package downloads.
The two RPC URLs may share infrastructure; agreement is not the same as
verification through an independently operated node.

Protecting any current owner or setter authority remains an operational
responsibility. This check does not authenticate the website or indexers, prove
that keepers are running, or verify every tool instance created by a factory.
