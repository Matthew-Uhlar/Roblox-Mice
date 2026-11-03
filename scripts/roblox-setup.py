#!/usr/bin/env python3
"""Create the Robux items and publish the place through Roblox Open Cloud.

Needs these environment variables (set them as environment secrets, never in the repo):
  ROBLOX_API_KEY      Open Cloud API key for this experience. Scopes:
                        game-pass:read, game-pass:write,
                        developer-product:read, developer-product:write,
                        universe-places:write (place publishing)
  ROBLOX_UNIVERSE_ID  the experience (universe) id
  ROBLOX_PLACE_ID     the start place id

Usage:
  scripts/roblox-setup.py items      create missing passes and products, write ids into Config/Monetization.luau
  scripts/roblox-setup.py publish    rojo build + publish a new Published place version
  scripts/roblox-setup.py all        items, then publish
  add --dry-run to print what would happen without calling Roblox

Idempotent: existing passes and products are matched by name and never duplicated.
Skipped: the subscription (cheese_club, needs Dashboard eligibility) and ad_reward
(needs ads eligibility). Both stay at assetId 0 and are hidden in game.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "src", "shared", "Config", "Monetization.luau")
API = "https://apis.roblox.com"
SKIP_KEYS = {"ad_reward"}


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"missing environment variable {name} (see the header of this script)")
    return value


def request(method, url, key, body=None, content_type=None):
    headers = {"x-api-key": key}
    if content_type:
        headers["Content-Type"] = content_type
    for attempt in range(5):
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:500]
            if err.code == 429 and attempt < 4:
                time.sleep(2 ** attempt)
                continue
            sys.exit(f"{method} {url} -> HTTP {err.code}: {detail}")
    sys.exit(f"{method} {url}: rate limited")


def multipart(fields):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def parse_items():
    """Read key/kind/name/price/benefit for each item from Monetization.luau."""
    src = open(CONFIG, encoding="utf-8").read()
    items = []
    for block in re.finditer(r"\{\s*key = \"([a-z0-9_]+)\",(.*?)\n\t\},", src, re.S):
        key, body = block.group(1), block.group(2)

        def field(pattern):
            m = re.search(pattern, body)
            return m.group(1) if m else None

        items.append(
            {
                "key": key,
                "kind": field(r'kind = "([a-z]+)"'),
                "name": field(r'name = "([^"]+)"'),
                "price": int(field(r"fallbackPrice = (\d+)") or 0),
                "benefit": field(r'benefit = "([^"]*)"') or "",
                "assetId": field(r"assetId = ([^,]+),"),
            }
        )
    return items


def list_all(url, key, list_field):
    out, token = [], None
    while True:
        page = request("GET", url + ("?pageSize=100" + (f"&pageToken={token}" if token else "")), key)
        out.extend(page.get(list_field) or [])
        token = page.get("nextPageToken")
        if not token:
            return out


def write_id(key, asset_id):
    src = open(CONFIG, encoding="utf-8").read()
    pattern = re.compile(r'(key = "' + re.escape(key) + r'",\s*kind = "[a-z]+",\s*assetId = )0,')
    new, n = pattern.subn(lambda m: m.group(1) + str(asset_id) + ",", src, count=1)
    if n:
        open(CONFIG, "w", encoding="utf-8").write(new)
    return n == 1


def cmd_items(dry):
    key, universe = env("ROBLOX_API_KEY"), env("ROBLOX_UNIVERSE_ID")
    items = [i for i in parse_items() if i["kind"] in ("pass", "product") and i["key"] not in SKIP_KEYS]
    passes_url = f"{API}/game-passes/v1/universes/{universe}/game-passes"
    products_url = f"{API}/developer-products/v2/universes/{universe}/developer-products"
    existing = {"pass": {}, "product": {}}
    if not dry:
        for gp in list_all(passes_url + "/creator", key, "gamePasses"):
            existing["pass"][gp.get("name")] = gp.get("gamePassId")
        for dp in list_all(products_url + "/creator", key, "developerProducts"):
            existing["product"][dp.get("name")] = dp.get("productId")
    for item in items:
        if item["assetId"] not in ("0", None):
            print(f"= {item['key']}: already configured ({item['assetId']})")
            continue
        found = existing[item["kind"]].get(item["name"])
        if found:
            print(f"~ {item['key']}: found existing {item['kind']} '{item['name']}' -> {found}")
            asset_id = found
        elif dry:
            print(f"+ {item['key']}: would create {item['kind']} '{item['name']}' at {item['price']} Robux")
            continue
        else:
            body, ctype = multipart(
                {
                    "name": item["name"],
                    "description": item["benefit"][:1000],
                    "isForSale": "true",
                    "price": str(item["price"]),
                    "isRegionalPricingEnabled": "true",
                }
            )
            url = passes_url if item["kind"] == "pass" else products_url
            res = request("POST", url, key, body, ctype)
            asset_id = res.get("gamePassId") or res.get("productId") or res.get("id")
            if not asset_id:
                sys.exit(f"created {item['key']} but the response had no id: {res}")
            print(f"+ {item['key']}: created {item['kind']} '{item['name']}' -> {asset_id}")
            time.sleep(0.5)  # stay under the 3-5 requests/second limit
        if not write_id(item["key"], asset_id):
            print(f"! {item['key']}: could not write id {asset_id} into Monetization.luau")


def cmd_publish(dry):
    key, universe, place = env("ROBLOX_API_KEY"), env("ROBLOX_UNIVERSE_ID"), env("ROBLOX_PLACE_ID")
    out = os.path.join(ROOT, "build", "Trunkfall.rbxlx")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(["rojo", "build", "-o", out], cwd=ROOT, check=True)
    if dry:
        print(f"would publish {out} to universe {universe}, place {place}")
        return
    with open(out, "rb") as fh:
        data = fh.read()
    url = f"{API}/universes/v1/{universe}/places/{place}/versions?versionType=Published"
    res = request("POST", url, key, data, "application/xml")
    print(f"published place version {res.get('versionNumber')}")


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = "--dry-run" in sys.argv
    cmd = args[0] if args else "help"
    if cmd == "items":
        cmd_items(dry)
    elif cmd == "publish":
        cmd_publish(dry)
    elif cmd == "all":
        cmd_items(dry)
        cmd_publish(dry)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
