#!/usr/bin/env bash
# Runs every Lune spec. Usage: scripts/test.sh [filter]
set -uo pipefail
cd "$(dirname "$0")/.."
LUNE="${LUNE:-lune}"
fail=0
count=0
for spec in tests/specs/*.spec.luau; do
	[[ -n "${1:-}" && "$spec" != *"$1"* ]] && continue
	count=$((count + 1))
	echo "▶ $spec"
	if ! "$LUNE" run "$spec"; then
		fail=$((fail + 1))
		echo "  ✗ FAILED: $spec"
	fi
done
echo
if [[ $count -eq 0 ]]; then
	echo "no specs matched"
	exit 1
fi
if [[ $fail -gt 0 ]]; then
	echo "$fail of $count spec files failed"
	exit 1
fi
echo "all $count spec files passed"
