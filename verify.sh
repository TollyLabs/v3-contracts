#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: Node.js is required; install Node.js 24 LTS as described in README.md" >&2
  exit 2
fi
if ! command -v pnpm >/dev/null 2>&1; then
  echo "ERROR: pnpm 10.33.4 is required; see README.md" >&2
  exit 2
fi

if [[ ! -f node_modules/.modules.yaml || ! -f node_modules/solc/index.js || ! -f node_modules/@openzeppelin/contracts/package.json ]]; then
  pnpm install --frozen-lockfile --ignore-scripts
fi

exec node scripts/verify.mjs "$@"
