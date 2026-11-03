#!/usr/bin/env bash
# Downloads pinned Linux x86_64 binaries of the toolchain into .tools/bin
# (gitignored). Used by the GitHub Actions workflows; also works in a cloud or
# Linux session without Cargo. Locally, ~/.cargo/bin installs work too:
# scripts/check.sh puts .tools/bin first on PATH, then ~/.cargo/bin.
#
#   scripts/install-tools.sh && export PATH="$PWD/.tools/bin:$PATH"
#
# Versions match what the specs were written against (Lune 0.11.x). StyLua's
# release binaries are built with Luau support. To bump a tool, change its
# version AND its sha256 below (sha256sum of the release zip).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
BIN="$ROOT/.tools/bin"
mkdir -p "$BIN"

# name | version | release zip URL | sha256 of the zip
TOOLS=(
	"rojo|7.7.1|https://github.com/rojo-rbx/rojo/releases/download/v7.7.1/rojo-7.7.1-linux-x86_64.zip|00feb4fa0829a1dd72b49df2639da519a352bfe13cadcd83969e2ba2bb5693c4"
	"lune|0.11.1|https://github.com/lune-org/lune/releases/download/v0.11.1/lune-0.11.1-linux-x86_64.zip|39859282ce677fce19e6eb45c37596a90a25c324c95b4e7e02d428b6cae294a1"
	"stylua|2.6.0|https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/stylua-linux-x86_64.zip|a485f72bbfa22e4642e77a84b5edc2611a5cab7477b34e2e709dd8f78e919895"
	"selene|0.31.0|https://github.com/Kampfkarren/selene/releases/download/0.31.0/selene-0.31.0-linux.zip|dac452422747999ec4919bbb8bb52992b66aae533b60022bf005669de8616671"
)

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
	echo "install-tools.sh only fetches Linux x86_64 binaries."
	echo "Elsewhere install with Cargo: cargo install --locked rojo lune selene; cargo install --locked stylua --features luau"
	exit 1
fi

unzip_to() { # zip, dir
	if command -v unzip >/dev/null 2>&1; then
		unzip -o -q "$1" -d "$2"
	else
		python3 -m zipfile -e "$1" "$2"
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for entry in "${TOOLS[@]}"; do
	IFS='|' read -r name version url sha <<<"$entry"
	if [[ -x "$BIN/$name" ]] && "$BIN/$name" --version 2>/dev/null | grep -qF "$version"; then
		echo "✓ $name $version (cached)"
		continue
	fi
	zip="$tmp/$name.zip"
	curl -fsSL --retry 3 --retry-delay 2 -o "$zip" "$url"
	got="$(sha256sum "$zip" | cut -d' ' -f1)"
	if [[ "$got" != "$sha" ]]; then
		echo "✗ $name: sha256 mismatch (expected $sha, got $got)" >&2
		exit 1
	fi
	mkdir -p "$tmp/$name"
	unzip_to "$zip" "$tmp/$name"
	found="$(find "$tmp/$name" -type f -name "$name" | head -1)"
	if [[ -z "$found" ]]; then
		echo "✗ $name: binary not found in $url" >&2
		exit 1
	fi
	install -m 0755 "$found" "$BIN/$name"
	echo "✓ $name $("$BIN/$name" --version | head -1)"
done

echo "tools installed in $BIN"
