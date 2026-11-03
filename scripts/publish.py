#!/usr/bin/env python3
"""Trunkfall's Roblox Open Cloud client (stdlib only). Runs in GitHub Actions.

Spec: docs/publishing/CLOUD_PUBLISHING_PLAYBOOK.md. Owner setup: docs/publishing/SETUP.md.

Subcommands:
  products [--dry-run]  create/update the game passes and developer products from
                        Config/Monetization.luau (matched by id, then by name; never
                        duplicated) and write their ids to the GENERATED file
                        src/shared/Config/ProductIds.luau
  place FILE            publish FILE (.rbxlx or .rbxl) as a new Published place
                        version; prints the version (and writes version=N to
                        $GITHUB_OUTPUT). Retries HTTP 409 "server busy" for ~17 min.
  configure [--dry-run] set the place name, description and server size, and the
                        universe device toggles (PLACE_SETTINGS / UNIVERSE_SETTINGS)
  smoke VERSION         run scripts/smoke.luau on that place version through Luau
                        Execution and assert the facts it returns
  smoke-sync            offline: check scripts/smoke.luau boots like Main.server.luau
  status                print name, visibility, server size and play URL
  assets [--dry-run]    upload the files in assets/models/manifest.json through the
                        Assets API and write their ids to the GENERATED file
                        src/shared/Config/AssetIds.luau (names with an id are skipped)

Environment (GitHub secret / variables; never commit or print them):
  ROBLOX_API_KEY           Open Cloud API key (permissions: SETUP.md §3)
  ROBLOX_UNIVERSE_ID       experience (universe) id
  ROBLOX_PLACE_ID          start place id
  ROBLOX_CREATOR_USER_ID   `assets` only: the user that owns uploaded assets
  ROBLOX_CREATOR_GROUP_ID  `assets` only, optional: upload as this group instead

`products` and `smoke` need `lune` on PATH (scripts/install-tools.sh).
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://apis.roblox.com"
CONFIG_DIR = os.path.join(ROOT, "src", "shared", "Config")
PRODUCT_IDS = os.path.join(CONFIG_DIR, "ProductIds.luau")
ASSET_IDS = os.path.join(CONFIG_DIR, "AssetIds.luau")
ASSET_MANIFEST = os.path.join(ROOT, "assets", "models", "manifest.json")
SMOKE_SCRIPT = os.path.join(ROOT, "scripts", "smoke.luau")
MAIN_SCRIPT = os.path.join(ROOT, "src", "server", "Main.server.luau")

# What `configure` sets. Edit here, then dispatch publish.yml.
PLACE_SETTINGS = {
    "displayName": "Trunkfall",
    "description": (
        "Elephant heroes vs a stampede of cheese-stealing mice! Team up in squads, "
        "pick your route, stomp swarms of mice and beat the boss of each cheese-themed "
        "world, then bank your cheese. Playing solo? Bot teammates (clearly labelled) "
        "join you, so you can always play."
    ),
    "serverSize": 12,  # 4 squads of 3
}
UNIVERSE_SETTINGS = {
    "desktopEnabled": True,
    "mobileEnabled": True,
    "tabletEnabled": True,
    "consoleEnabled": False,  # not play-tested with a gamepad on console yet
}

# Assets API content types (create.roblox.com/docs/cloud/guides/usage-assets).
CONTENT_TYPES = {
    ".fbx": "model/fbx",
    ".gltf": "model/gltf+json",
    ".glb": "model/gltf-binary",
    ".rbxm": "model/x-rbxm",
    ".rbxmx": "model/x-rbxm",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".bmp": "image/bmp",
    ".tga": "image/tga",
    ".mp3": "audio/mpeg",
    ".ogg": "audio/ogg",
    ".wav": "audio/wav",
    ".flac": "audio/flac",
    ".mp4": "video/mp4",
    ".mov": "video/mov",
}
ASSET_TYPES = {"Model", "Decal", "Image", "Audio", "Animation", "Video"}
MAX_ASSET_BYTES = 20 * 1024 * 1024


class ApiError(Exception):
    def __init__(self, method, path, code, detail):
        super().__init__(f"{method} {path} -> HTTP {code}: {detail}")
        self.code = code


def fail(msg):
    print(f"::error::{msg}" if os.environ.get("GITHUB_ACTIONS") else f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def env(name, required=True):
    value = os.environ.get(name, "").strip()
    if required and not value:
        fail(f"{name} is not set (see docs/publishing/SETUP.md)")
    return value


def ids():
    universe, place = env("ROBLOX_UNIVERSE_ID"), env("ROBLOX_PLACE_ID")
    for name, value in (("ROBLOX_UNIVERSE_ID", universe), ("ROBLOX_PLACE_ID", place)):
        if not value.isdigit():
            fail(f"{name} must be a number")
    return universe, place


def summary(markdown):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(markdown + "\n")


def output(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{name}={value}\n")


def request(method, path, body=None, content_type=None, timeout=300):
    """One Open Cloud call. Retries 429 (honours Retry-After) and 5xx. The key is
    only ever put in the request header; errors show method, path and body."""
    key = env("ROBLOX_API_KEY")
    url = path if path.startswith("http") else API + path
    shown = urllib.parse.urlsplit(url).path
    headers = {"x-api-key": key, "Accept": "application/json"}
    if content_type:
        headers["Content-Type"] = content_type
    attempts = 7
    for attempt in range(attempts):
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:800]
            retryable = err.code == 429 or err.code >= 500
            if retryable and attempt < attempts - 1:
                wait = min(60.0, 2.0**attempt)
                hint = err.headers.get("Retry-After") or err.headers.get("x-ratelimit-reset")
                try:
                    wait = max(wait, min(120.0, float(hint))) if hint else wait
                except ValueError:
                    pass
                print(f"  {method} {shown}: HTTP {err.code}, retrying in {wait:.0f}s")
                time.sleep(wait)
                continue
            raise ApiError(method, shown, err.code, detail) from None
        except (urllib.error.URLError, TimeoutError) as err:
            if attempt < attempts - 1:
                print(f"  {method} {shown}: {err}, retrying")
                time.sleep(2.0**attempt)
                continue
            raise ApiError(method, shown, 0, str(err)) from None
    raise ApiError(method, shown, 429, "rate limited")


def multipart(fields, files=()):
    """fields: {name: str}; files: [(field, filename, content_type, bytes)]."""
    boundary = uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        if isinstance(value, tuple):  # (value, content_type)
            value, ctype = value
            out.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n'
                f"Content-Type: {ctype}\r\n\r\n".encode()
                + value.encode()
                + b"\r\n"
            )
        else:
            out.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
                + str(value).encode()
                + b"\r\n"
            )
    for field, filename, ctype, data in files:
        out.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
            f"Content-Type: {ctype}\r\n\r\n".encode()
            + data
            + b"\r\n"
        )
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def luau_value(v):
    return str(int(v)) if isinstance(v, (int, float)) and not isinstance(v, bool) else json.dumps(str(v))


# ---------------------------------------------------------------- products


def load_catalog():
    try:
        res = subprocess.run(
            ["lune", "run", "scripts/catalog.luau"], cwd=ROOT, capture_output=True, text=True, check=False
        )
    except FileNotFoundError:
        fail("lune is not on PATH (run scripts/install-tools.sh)")
    if res.returncode != 0:
        fail(f"scripts/catalog.luau failed:\n{res.stdout}{res.stderr}")
    return json.loads(res.stdout.strip().splitlines()[-1])


def write_product_ids(catalog, values):
    lines = [
        "--!strict",
        "-- GENERATED by `scripts/publish.py products` (docs/publishing/SETUP.md). Don't edit:",
        "-- the publish workflow rewrites and commits this file. 0 = not created on Roblox yet",
        "-- (the game hides that item). Config/Monetization.luau uses these ids for items",
        "-- whose own assetId is 0.",
        "return {",
    ]
    for item in catalog:
        lines.append(f"\t{item['key']} = {luau_value(values.get(item['key'], 0) or 0)},")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    old = open(PRODUCT_IDS, encoding="utf-8").read() if os.path.exists(PRODUCT_IDS) else ""
    if text != old:
        with open(PRODUCT_IDS, "w", encoding="utf-8") as fh:
            fh.write(text)


def list_all(path, field):
    out, token = [], None
    while True:
        query = "?pageSize=100" + (f"&pageToken={urllib.parse.quote(token)}" if token else "")
        page = request("GET", path + query)
        out.extend(page.get(field) or [])
        token = page.get("nextPageToken")
        if not token:
            return out


def entry_price(entry):
    info = entry.get("priceInformation") or {}
    price = info.get("defaultPriceInRobux", entry.get("price"))
    return int(price) if price is not None else None


def cmd_products(dry):
    catalog = load_catalog()
    values = {i["key"]: i["generatedId"] for i in catalog}
    write_product_ids(catalog, values)  # ensures every key is present
    items = [i for i in catalog if i["kind"] in ("pass", "product") and not i["adOnly"]]
    skipped = [i["key"] for i in catalog if i not in items]
    print(f"{len(items)} items to sync; not synced (subscription / ad-only): {', '.join(skipped)}")
    if dry and not os.environ.get("ROBLOX_API_KEY"):
        for i in items:
            print(f"  would sync {i['kind']} {i['key']!r}: {i['name']!r} at {i['price']} Robux")
        return
    universe, _ = ids()
    base = {
        "pass": f"/game-passes/v1/universes/{universe}/game-passes",
        "product": f"/developer-products/v2/universes/{universe}/developer-products",
    }
    id_field = {"pass": "gamePassId", "product": "productId"}
    existing = {
        "pass": list_all(base["pass"] + "/creator", "gamePasses"),
        "product": list_all(base["product"] + "/creator", "developerProducts"),
    }
    print(f"found {len(existing['pass'])} passes and {len(existing['product'])} products on Roblox")
    rows = []
    for item in items:
        kind, key = item["kind"], item["key"]
        hand_id = item["assetId"] not in (0, "0", None) and item["assetId"] != item["generatedId"]
        if hand_id:
            print(f"= {key}: id {item['assetId']} is set in Monetization.luau; left alone")
            rows.append((key, item["assetId"], "set by hand"))
            continue
        desired = {
            "name": item["name"],
            "description": item["description"][:1000],
            "price": int(item["price"]),
        }
        entries = existing[kind]
        current = None
        if item["generatedId"]:
            current = next((e for e in entries if str(e.get(id_field[kind])) == str(item["generatedId"])), None)
        if current is None:
            current = next((e for e in entries if e.get("name") == item["name"]), None)
        fields = {
            "name": desired["name"],
            "description": desired["description"],
            "price": str(desired["price"]),
            "isForSale": "true",
            "isRegionalPricingEnabled": "true",
        }
        if current is not None:
            asset_id = current.get(id_field[kind])
            changed = [
                f
                for f, have in (
                    ("name", current.get("name")),
                    ("description", current.get("description") or ""),
                    ("price", entry_price(current)),
                )
                if have != desired[f]
            ]
            if current.get("isForSale") is False:
                changed.append("isForSale")
            if not changed:
                print(f"= {key}: {kind} {asset_id} up to date")
                action = "unchanged"
            elif dry:
                print(f"~ {key}: would update {kind} {asset_id} ({', '.join(changed)})")
                action = "would update"
            else:
                body, ctype = multipart(fields)
                request("PATCH", f"{base[kind]}/{asset_id}", body, ctype)
                print(f"~ {key}: updated {kind} {asset_id} ({', '.join(changed)})")
                action = "updated"
                time.sleep(0.5)
        elif dry:
            print(f"+ {key}: would create {kind} {item['name']!r} at {item['price']} Robux")
            rows.append((key, 0, "would create"))
            continue
        else:
            body, ctype = multipart(fields)
            res = request("POST", base[kind], body, ctype)
            asset_id = res.get(id_field[kind]) or res.get("id")
            if not asset_id:
                fail(f"created {key} but the response had no id: {json.dumps(res)[:300]}")
            print(f"+ {key}: created {kind} {item['name']!r} -> {asset_id}")
            action = "created"
            time.sleep(0.5)  # stay well under the per-second write limits
        values[key] = int(asset_id)
        if not dry:
            write_product_ids(catalog, values)  # keep progress if a later call fails
        rows.append((key, asset_id, action))
    summary("### Products\n\n| key | id | action |\n|---|---|---|\n" + "\n".join(f"| {k} | {i} | {a} |" for k, i, a in rows))


# ---------------------------------------------------------------- place / configure / status


def cmd_place(path):
    universe, place = ids()
    if not os.path.isfile(path):
        fail(f"{path} not found (scripts/check.sh builds it)")
    ctype = "application/xml" if path.endswith(".rbxlx") else "application/octet-stream"
    data = open(path, "rb").read()
    print(f"publishing {os.path.basename(path)} ({len(data) // 1024} KB) to place {place}")
    waits = [30, 60, 90, 120, 150, 180, 180, 180]  # ~16.5 min of "server busy" retries
    for attempt in range(len(waits) + 1):
        try:
            res = request("POST", f"/universes/v1/{universe}/places/{place}/versions?versionType=Published", data, ctype)
            break
        except ApiError as err:
            if err.code != 409 or attempt == len(waits):
                if err.code == 409:
                    fail(f"{err}\nThe place is busy: close it in Roblox Studio (and Team Create), then re-run.")
                fail(str(err))
            print(f"  HTTP 409 (server busy: is the place open in Studio?), retry in {waits[attempt]}s")
            time.sleep(waits[attempt])
    version = res.get("versionNumber")
    if not version:
        fail(f"publish response had no versionNumber: {json.dumps(res)[:300]}")
    print(f"published place version {version}")
    output("version", version)
    summary(f"### Published\n\nPlace version **{version}**: https://www.roblox.com/games/{place}")


def cmd_configure(dry):
    universe, place = ids()
    place_mask = ",".join(PLACE_SETTINGS)
    universe_mask = ",".join(UNIVERSE_SETTINGS)
    if dry:
        print(f"would PATCH place {place}: {json.dumps(PLACE_SETTINGS)}")
        print(f"would PATCH universe {universe}: {json.dumps(UNIVERSE_SETTINGS)}")
        return
    body = json.dumps(PLACE_SETTINGS).encode()
    res = request("PATCH", f"/cloud/v2/universes/{universe}/places/{place}?updateMask={place_mask}", body, "application/json")
    print(f"place: name={res.get('displayName')!r} serverSize={res.get('serverSize')}")
    body = json.dumps(UNIVERSE_SETTINGS).encode()
    res = request("PATCH", f"/cloud/v2/universes/{universe}?updateMask={universe_mask}", body, "application/json")
    print("universe: " + ", ".join(f"{k}={res.get(k)}" for k in UNIVERSE_SETTINGS))


def cmd_status():
    universe, place = ids()
    uni = request("GET", f"/cloud/v2/universes/{universe}")
    plc = request("GET", f"/cloud/v2/universes/{universe}/places/{place}")
    url = f"https://www.roblox.com/games/{place}"
    rows = [
        ("Name", uni.get("displayName") or plc.get("displayName")),
        ("Visibility", uni.get("visibility")),
        ("Server size", plc.get("serverSize")),
        ("Devices", ", ".join(k[: -len("Enabled")] for k in UNIVERSE_SETTINGS if uni.get(k)) or "none"),
        ("Play URL", url),
    ]
    for k, v in rows:
        print(f"{k + ':':13} {v}")
    if uni.get("visibility") != "PUBLIC":
        print("Not public yet: the owner flips Configure -> Privacy -> Public (docs/publishing/SETUP.md §6).")
    summary("### Status\n\n| | |\n|---|---|\n" + "\n".join(f"| {k} | {v} |" for k, v in rows))


# ---------------------------------------------------------------- smoke test


def lua_list(src, name):
    m = re.search(r"local " + name + r"\s*=\s*\{([^}]*)\}", src)
    return re.findall(r'"(\w+)"', m.group(1)) if m else None


def cmd_smoke_sync():
    """The smoke test must boot the same services, in the same order, as Main."""
    main = open(MAIN_SCRIPT, encoding="utf-8").read()
    smoke = open(SMOKE_SCRIPT, encoding="utf-8").read()
    if re.search(r'(WaitForChild|FindFirstChild)\(\s*"Boot"\s*\)|\.Boot\b', main):
        print("smoke-sync: Main.server.luau delegates to Server/Boot; the smoke test calls Boot.start() too")
        return
    optional = re.findall(r'^\s*initOptional\(\s*"(\w+)"\s*\)', main, re.M)
    modvars = dict(re.findall(r'^\s*local (\w+) = require\(Services:WaitForChild\(\s*"(\w+)"\s*\)\)', main, re.M))
    required = [modvars[v] for v in re.findall(r"^\s*(\w+)\.init\(\)", main, re.M) if v in modvars]
    problems = []
    if not optional and not required:
        problems.append("could not find any initOptional(...) or <Service>.init() calls in Main.server.luau")
    if "Net.setupServer()" not in main:
        problems.append("Main.server.luau no longer calls Net.setupServer()")
    if lua_list(smoke, "OPTIONAL") != optional:
        problems.append(f"OPTIONAL: Main has {optional}, smoke.luau has {lua_list(smoke, 'OPTIONAL')}")
    if lua_list(smoke, "REQUIRED") != required:
        problems.append(f"REQUIRED: Main has {required}, smoke.luau has {lua_list(smoke, 'REQUIRED')}")
    if problems:
        print("smoke-sync FAILED: scripts/smoke.luau must boot like src/server/Main.server.luau.")
        for p in problems:
            print("  - " + p)
        print("Fix: update the MIRROR in scripts/smoke.luau, or move Main's boot into")
        print("src/server/Boot.luau (docs/publishing/SMOKE.md) so there is one source of truth.")
        sys.exit(1)
    print(f"smoke-sync: OK ({len(optional)} optional + {len(required)} required services)")


def task_logs(path):
    try:
        res = request("GET", f"/cloud/v2/{path}/logs?maxPageSize=100")
    except ApiError as err:
        return [f"(could not read logs: {err})"]
    lines = []
    for page in res.get("luauExecutionSessionTaskLogs") or []:
        lines.extend(page.get("messages") or [])
    return lines


def run_task(universe, place, version, script, poll_seconds=300):
    body = json.dumps({"script": script, "timeout": "180s"}).encode()
    task = request(
        "POST",
        f"/cloud/v2/universes/{universe}/places/{place}/versions/{version}/luau-execution-session-tasks",
        body,
        "application/json",
    )
    path = task.get("path")
    if not path:
        fail(f"no task path in response: {json.dumps(task)[:300]}")
    print(f"smoke task {path.rsplit('/', 1)[-1]} started")
    deadline = time.time() + poll_seconds
    while task.get("state") not in ("COMPLETE", "FAILED", "CANCELLED"):
        if time.time() > deadline:
            return task, path, True
        time.sleep(3)
        task = request("GET", f"/cloud/v2/{path}")
    return task, path, False


def expected_configured():
    try:
        return sum(1 for i in load_catalog() if i["assetId"] not in (0, "0", None))
    except SystemExit:
        return None


def cmd_smoke(version):
    universe, place = ids()
    if not str(version).isdigit():
        fail(f"smoke needs the published version number, got {version!r}")
    script = open(SMOKE_SCRIPT, encoding="utf-8").read()
    for attempt in (1, 2):
        task, path, timed_out = run_task(universe, place, version, script)
        if not timed_out:
            break
        print(f"task still {task.get('state')} after the poll limit; logs so far:")
        for line in task_logs(path):
            print("  | " + line)
        if attempt == 2:
            fail("smoke task timed out twice (see the logs above)")
        print("retrying once with a fresh task (the first task sometimes stalls)")
    logs = task_logs(path)
    if logs:
        print("task log:")
        for line in logs:
            print("  | " + line)
    if task.get("state") != "COMPLETE":
        err = task.get("error") or {}
        fail(f"smoke task {task.get('state')}: {err.get('code')} {err.get('message')}")
    results = (task.get("output") or {}).get("results") or []
    if not results:
        fail("smoke task returned no results")
    facts = results[0]
    if isinstance(facts, str):
        facts = json.loads(facts)

    services = facts.get("services") or {}
    want_configured = expected_configured()
    checks = [
        ("boot ran without an error", not facts.get("bootError"), facts.get("bootError") or facts.get("bootMode")),
        ("place version matches", str(facts.get("placeVersion")) == str(version), facts.get("placeVersion")),
        ("universe matches", str(facts.get("gameId")) == universe, facts.get("gameId")),
        ("services reported", facts.get("bootMode") == "auto" or len(services) > 0, len(services)),
        ("every service ok", all(v == "ok" for v in services.values()), {k: v for k, v in services.items() if v != "ok"} or "all ok"),
        ("all remotes created", facts.get("remotes") == facts.get("expectedRemotes") and (facts.get("remotes") or 0) > 0, f"{facts.get('remotes')}/{facts.get('expectedRemotes')}"),
        ("a SpawnLocation exists", (facts.get("spawnLocations") or 0) >= 1, facts.get("spawnLocations")),
        ("string require works live", facts.get("stringRequire") is True, facts.get("stringRequireError") or "ok"),
        ("no errors logged", facts.get("errorCount") == 0, facts.get("errors") or 0),
    ]
    if want_configured is not None:
        checks.append(("Robux items configured", facts.get("configuredItems") == want_configured, f"{facts.get('configuredItems')} (expected {want_configured})"))

    print("\nsmoke facts:")
    for k in sorted(facts):
        if k not in ("services", "errors", "warnings"):
            print(f"  {k:18} {facts[k]}")
    for k, v in services.items():
        print(f"  service {k:10} {v}")
    for w in facts.get("warnings") or []:
        print(f"  warning: {w}")
    print("\nchecks:")
    bad = 0
    rows = []
    for name, ok, detail in checks:
        bad += 0 if ok else 1
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")
        rows.append(f"| {'✅' if ok else '❌'} | {name} | {str(detail)[:200]} |")
    summary(f"### Smoke test (version {version})\n\n| | check | detail |\n|---|---|---|\n" + "\n".join(rows))
    if bad:
        fail(f"smoke test failed {bad} of {len(checks)} checks")
    print("Smoke test passed")


# ---------------------------------------------------------------- assets


def read_asset_ids():
    if not os.path.exists(ASSET_IDS):
        return {}
    src = open(ASSET_IDS, encoding="utf-8").read()
    out = {}
    for quoted, bare, value in re.findall(r'^\s*(?:\["([^"]+)"\]|([A-Za-z_]\w*))\s*=\s*(\d+)', src, re.M):
        out[quoted or bare] = int(value)
    return out


def write_asset_ids(values):
    lines = [
        "--!strict",
        "-- GENERATED by `scripts/publish.py assets` from assets/models/manifest.json",
        "-- (docs/publishing/SETUP.md). Don't edit: upload-assets.yml rewrites and commits it.",
        "-- Maps a manifest name to its Roblox asset id (use rbxassetid://<id>).",
    ]
    if values:
        lines.append("return {")
        for name in sorted(values):
            lines.append(f"\t[{json.dumps(name)}] = {int(values[name])},")
        lines.append("}")
    else:
        lines.append("return {}")
    text = "\n".join(lines) + "\n"
    old = open(ASSET_IDS, encoding="utf-8").read() if os.path.exists(ASSET_IDS) else ""
    if text != old:
        with open(ASSET_IDS, "w", encoding="utf-8") as fh:
            fh.write(text)


def load_manifest():
    if not os.path.exists(ASSET_MANIFEST):
        return []
    data = json.load(open(ASSET_MANIFEST, encoding="utf-8"))
    entries = data.get("assets") if isinstance(data, dict) else data
    if not isinstance(entries, list):
        fail("assets/models/manifest.json must be a list of {name, path, type} (or {\"assets\": [...]})")
    base = os.path.dirname(ASSET_MANIFEST)
    out, seen = [], set()
    for i, e in enumerate(entries):
        name, path, kind = e.get("name"), e.get("path"), e.get("type", "Model")
        if not name or not path:
            fail(f"manifest entry {i} needs a name and a path")
        if name in seen:
            fail(f"manifest name {name!r} is listed twice")
        seen.add(name)
        if kind == "Mesh":
            fail(
                f"{name}: type Mesh only accepts Roblox mesh data. Upload .fbx/.glb/.gltf as type "
                "Model (it imports as a Model of MeshParts)."
            )
        if kind not in ASSET_TYPES:
            fail(f"{name}: unsupported type {kind!r} (use one of {', '.join(sorted(ASSET_TYPES))})")
        full = next((p for p in (os.path.join(base, path), os.path.join(ROOT, path)) if os.path.isfile(p)), None)
        if not full:
            fail(f"{name}: file {path} not found (paths are relative to assets/models/)")
        ext = os.path.splitext(full)[1].lower()
        if ext not in CONTENT_TYPES:
            fail(f"{name}: unsupported file type {ext}")
        out.append({**e, "name": name, "type": kind, "file": full, "contentType": CONTENT_TYPES[ext]})
    return out


def creator():
    group = env("ROBLOX_CREATOR_GROUP_ID", required=False)
    if group:
        return {"groupId": group}
    user = env("ROBLOX_CREATOR_USER_ID", required=False)
    if not user:
        fail("ROBLOX_CREATOR_USER_ID is not set (or set ROBLOX_CREATOR_GROUP_ID); see docs/publishing/SETUP.md")
    if not user.isdigit():
        fail("ROBLOX_CREATOR_USER_ID must be a number")
    return {"userId": user}


def wait_operation(op, seconds=300):
    deadline = time.time() + seconds
    while not op.get("done"):
        if time.time() > deadline:
            raise RuntimeError(f"operation {op.get('path')} not done after {seconds}s")
        time.sleep(2)
        op = request("GET", f"/assets/v1/{op['path']}")
    if op.get("error"):
        raise RuntimeError(f"{op['error'].get('code')} {op['error'].get('message')}")
    return op.get("response") or {}


def cmd_assets(dry):
    entries = load_manifest()
    have = read_asset_ids()
    write_asset_ids(have)
    todo = [e for e in entries if not have.get(e["name"])]
    print(f"{len(entries)} assets in the manifest, {len(entries) - len(todo)} already uploaded, {len(todo)} to upload")
    if not todo:
        return
    for e in todo:
        size = os.path.getsize(e["file"])
        if size > MAX_ASSET_BYTES:
            fail(f"{e['name']}: {size // 1024} KB is over the Assets API's 20 MB limit")
    if dry:
        for e in todo:
            print(f"  would upload {e['type']} {e['name']!r} from {os.path.relpath(e['file'], ROOT)}")
        return
    owner = creator()
    failed = []
    for e in todo:
        req = {
            "assetType": e["type"],
            "displayName": e.get("displayName", e["name"])[:50],
            "description": e.get("description", f"Trunkfall: {e['name']}")[:1000],
            "creationContext": {"creator": owner},
        }
        body, ctype = multipart(
            {"request": (json.dumps(req), "application/json")},
            [("fileContent", os.path.basename(e["file"]), e["contentType"], open(e["file"], "rb").read())],
        )
        try:
            op = request("POST", "/assets/v1/assets", body, ctype)
            asset = wait_operation(op)
            asset_id = asset.get("assetId") or (asset.get("path") or "").rsplit("/", 1)[-1]
            state = (asset.get("moderationResult") or {}).get("moderationState", "")
            if not str(asset_id).isdigit():
                raise RuntimeError(f"no asset id in {json.dumps(asset)[:300]}")
            if state == "MODERATION_STATE_REJECTED":
                raise RuntimeError(f"asset {asset_id} was rejected by moderation")
        except (ApiError, RuntimeError) as err:
            print(f"✗ {e['name']}: {err}")
            failed.append(e["name"])
            continue
        have[e["name"]] = int(asset_id)
        write_asset_ids(have)  # keep progress so a re-run never uploads it twice
        print(f"+ {e['name']}: {e['type']} -> {asset_id} {state}".rstrip())
        time.sleep(0.5)
    if failed:
        fail(f"{len(failed)} uploads failed: {', '.join(failed)}")


# ---------------------------------------------------------------- main


def main(argv):
    dry = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    cmd = args[0] if args else "help"
    try:
        if cmd == "products":
            cmd_products(dry)
        elif cmd == "place" and len(args) == 2:
            cmd_place(args[1])
        elif cmd == "configure":
            cmd_configure(dry)
        elif cmd == "smoke" and len(args) == 2:
            cmd_smoke(args[1])
        elif cmd == "smoke-sync":
            cmd_smoke_sync()
        elif cmd == "status":
            cmd_status()
        elif cmd == "assets":
            cmd_assets(dry)
        else:
            print(__doc__)
            sys.exit(0 if cmd in ("help", "-h", "--help") else 2)
    except ApiError as err:
        hint = ""
        if err.code in (401, 403):
            hint = "\nCheck the API key's permissions, experience and IP allow-list (docs/publishing/SETUP.md §3)."
        fail(f"{err}{hint}")


if __name__ == "__main__":
    main(sys.argv[1:])
