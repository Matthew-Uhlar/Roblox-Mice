#!/usr/bin/env python3
"""Deprecated: thin wrapper around scripts/publish.py (kept for old docs and prompts).

  scripts/roblox-setup.py items      -> scripts/publish.py products
  scripts/roblox-setup.py publish    -> rojo build, then scripts/publish.py place build/Trunkfall.rbxlx
  scripts/roblox-setup.py all        -> both
  --dry-run is passed through to `products`.

Prefer the GitHub workflows (docs/publishing/SETUP.md). Ids now go to the generated
src/shared/Config/ProductIds.luau, not into Config/Monetization.luau.
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUBLISH = [sys.executable, os.path.join(ROOT, "scripts", "publish.py")]


def run(args):
    code = subprocess.call(args, cwd=ROOT)
    if code:
        sys.exit(code)


def main():
    dry = "--dry-run" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    cmd = args[0] if args else "help"
    if cmd not in ("items", "publish", "all"):
        print(__doc__)
        return
    if cmd in ("items", "all"):
        run(PUBLISH + ["products"] + (["--dry-run"] if dry else []))
    if cmd in ("publish", "all"):
        out = os.path.join("build", "Trunkfall.rbxlx")
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
        run(["rojo", "build", "-o", out])
        if dry:
            print(f"would publish {out}")
            return
        run(PUBLISH + ["place", out])


if __name__ == "__main__":
    main()
