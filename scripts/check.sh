#!/usr/bin/env bash
# Full quality gate: format check, lint, compile, unit tests, Rojo build.
set -uo pipefail
cd "$(dirname "$0")/.."
# Pinned tools from scripts/install-tools.sh (CI) win over Cargo installs (local).
export PATH="$PWD/.tools/bin:$HOME/.cargo/bin:$PATH"
status=0
step() { echo; echo "── $1"; }

step "stylua --check"
stylua --check src tests >/dev/null 2>&1 || { stylua --check src tests 2>&1 | head -40; echo "format: FAIL (run: stylua src tests)"; status=1; }

step "selene"
selene src tests || status=1

step "luau compile"
lune run scripts/compile-check.luau src tests scripts || status=1

step "unit tests (lune)"
scripts/test.sh || status=1

step "rojo build"
mkdir -p build
rojo build -o build/Trunkfall.rbxlx || status=1

step "smoke boot mirror (warning only)"
python3 scripts/publish.py smoke-sync || echo "WARNING: scripts/smoke.luau no longer boots like Main.server.luau. publish.yml will refuse to publish until it does."

echo
if [[ $status -eq 0 ]]; then echo "CHECK PASSED"; else echo "CHECK FAILED"; fi
exit $status
