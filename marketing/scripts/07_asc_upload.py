#!/usr/bin/env python3
"""Step 7 — push the screenshots and app preview into App Store Connect via the ASC API.

The ASC web uploader needs a real file picker, which an automated browser can't drive, so this
talks to the App Store Connect API directly. Nothing but the Python standard library + the
`openssl` CLI (the JWT is ES256-signed by shelling out, so no pip packages are needed).

One-time setup (App Store Connect → Users and Access → Integrations → App Store Connect API →
Team Keys → "+" → role App Manager; download the .p8 ONCE):

    export ASC_KEY_ID=ABC123DEF4            # the key's ID
    export ASC_ISSUER_ID=xxxxxxxx-...        # Issuer ID shown above the key table
    export ASC_KEY_PATH=~/.private_keys/AuthKey_ABC123DEF4.p8   # default if unset

Usage (run from the repo root):

    python3 marketing/scripts/07_asc_upload.py --version 1.1 --dry-run     # show the plan
    python3 marketing/scripts/07_asc_upload.py --version 1.1               # screenshots + preview
    python3 marketing/scripts/07_asc_upload.py --version 1.1 --screenshots-only
    python3 marketing/scripts/07_asc_upload.py --version 1.1 --previews-only

What it does, per locale of the given (editable) version:
  * for each display slot below: create the screenshot set if missing, delete what's in it, upload
    01…06 in order, and pin the order;
  * for the iPhone preview slots: create the preview set if missing, delete what's in it, upload the
    hero preview with its poster frame.
It never touches text metadata (done in the web UI — see appstore-metadata.md) or builds.

Display-type mapping (ASC API enum → folder):
  APP_IPHONE_67          "iPhone 6.9/6.7-inch"  ← screenshots/iphone-6.9-1320x2868
  APP_IPHONE_65          "iPhone 6.5-inch"      ← screenshots/iphone-6.5-1242x2688
  APP_IPAD_PRO_3GEN_129  "iPad 13/12.9-inch"    ← screenshots/ipad-13
  APP_IPAD_PRO_129       "iPad 12.9-inch (2nd)" ← screenshots/ipad-12.9
  previews: IPHONE_67 and IPHONE_65            ← preview/MotionTrails-Preview-Hero-886x1920.mp4
"""
import argparse, base64, hashlib, json, os, ssl, subprocess, sys, time, urllib.request, urllib.error, urllib.parse

# python.org builds ship without CA certs wired in; fall back to the macOS system bundle.
_SSL = ssl.create_default_context()
for _ca in ("/etc/ssl/cert.pem", "/opt/homebrew/etc/ca-certificates/cert.pem"):
    if os.path.exists(_ca):
        try: _SSL.load_verify_locations(_ca)
        except Exception: pass

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MK = os.path.join(ROOT, "marketing")
API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.frank.motiontrails"

SCREENSHOT_SLOTS = [
    ("APP_IPHONE_67",         "screenshots/iphone-6.9-1320x2868"),
    ("APP_IPHONE_65",         "screenshots/iphone-6.5-1242x2688"),
    ("APP_IPAD_PRO_3GEN_129", "screenshots/ipad-13"),
    ("APP_IPAD_PRO_129",      "screenshots/ipad-12.9"),
]
PREVIEW_SLOTS = ["IPHONE_67", "IPHONE_65"]
PREVIEW_FILE = "preview/MotionTrails-Preview-Hero-886x1920.mp4"
PREVIEW_POSTER = "00:00:05:15"   # hh:mm:ss:ff at 30 fps — the dense sunset ribbon
EDITABLE_STATES = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                   "INVALID_BINARY", "WAITING_FOR_REVIEW", "READY_FOR_REVIEW"}

# ---------------------------------------------------------------------------------------------
# Auth — ES256 JWT signed with the .p8 via the openssl CLI (DER signature → raw r||s).
# ---------------------------------------------------------------------------------------------
def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der: bytes) -> bytes:
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        ln = der[i + 1]; i += 2
        val = der[i:i + ln]; i += ln
        val = val.lstrip(b"\x00").rjust(32, b"\x00")
        out += val
    return out

_token_cache = {"jwt": None, "exp": 0}

def token() -> str:
    now = int(time.time())
    if _token_cache["jwt"] and now < _token_cache["exp"] - 60:
        return _token_cache["jwt"]
    kid = os.environ.get("ASC_KEY_ID"); iss = os.environ.get("ASC_ISSUER_ID")
    path = os.path.expanduser(os.environ.get("ASC_KEY_PATH", f"~/.private_keys/AuthKey_{kid}.p8"))
    if not (kid and iss and os.path.exists(path)):
        sys.exit("set ASC_KEY_ID, ASC_ISSUER_ID and have the .p8 at ASC_KEY_PATH (see the script header)")
    header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    payload = {"iss": iss, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
              b64url(json.dumps(payload, separators=(",", ":")).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=signing.encode(),
                         capture_output=True, check=True).stdout
    jwt = signing + "." + b64url(der_to_raw(der))
    _token_cache.update(jwt=jwt, exp=payload["exp"])
    return jwt

def api(method: str, path: str, body=None, params=None):
    url = path if path.startswith("http") else API + path
    if params: url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data is not None: req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} → HTTP {e.code}: {e.read().decode()[:800]}")

def all_pages(path, params=None):
    out, nxt = [], None
    res = api("GET", path, params=params)
    out += res.get("data", [])
    while res.get("links", {}).get("next"):
        res = api("GET", res["links"]["next"]); out += res.get("data", [])
    return out

# ---------------------------------------------------------------------------------------------
# Upload helpers (reserve → PUT parts → commit with MD5)
# ---------------------------------------------------------------------------------------------
def put_parts(ops, data: bytes):
    for op in ops:
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for h in op.get("requestHeaders", []):
            req.add_header(h["name"], h["value"])
        with urllib.request.urlopen(req, context=_SSL) as r:
            r.read()

def upload_asset(kind: str, rel: str, set_id: str, path: str, extra_attrs=None):
    """kind: appScreenshots|appPreviews; rel: appScreenshotSet|appPreviewSet (the relationship
    name — its data.type is the plural resource type, e.g. appScreenshotSets)."""
    data = open(path, "rb").read()
    attrs = {"fileName": os.path.basename(path), "fileSize": len(data)}
    if extra_attrs: attrs.update(extra_attrs)
    res = api("POST", f"/{kind}", {"data": {"type": kind, "attributes": attrs,
              "relationships": {rel: {"data": {"type": rel + "s", "id": set_id}}}}})
    asset = res["data"]
    put_parts(asset["attributes"]["uploadOperations"], data)
    commit = {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}
    if extra_attrs and "previewFrameTimeCode" in extra_attrs:
        commit["previewFrameTimeCode"] = extra_attrs["previewFrameTimeCode"]
    api("PATCH", f"/{kind}/{asset['id']}", {"data": {"type": kind, "id": asset["id"], "attributes": commit}})
    return asset["id"]

# ---------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="App Store version string, e.g. 1.1")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--screenshots-only", action="store_true")
    ap.add_argument("--previews-only", action="store_true")
    args = ap.parse_args()
    do_shots = not args.previews_only
    do_prev = not args.screenshots_only

    apps = api("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps: sys.exit(f"no app with bundle id {BUNDLE_ID}")
    app = apps[0]
    versions = api("GET", f"/apps/{app['id']}/appStoreVersions",
                   params={"filter[platform]": "IOS", "filter[versionString]": args.version})["data"]
    if not versions: sys.exit(f"version {args.version} not found — create it in App Store Connect first")
    ver = versions[0]
    state = ver["attributes"]["appStoreState"]
    print(f"app {app['attributes']['name']} ({app['id']}) · version {args.version} · state {state}")
    if state not in EDITABLE_STATES:
        sys.exit(f"version is {state}; assets can only change on a version that is being prepared")

    locs = api("GET", f"/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        lid = loc["id"]; locale = loc["attributes"]["locale"]
        print(f"\nlocale {locale}")

        if do_shots:
            sets = {s["attributes"]["screenshotDisplayType"]: s
                    for s in all_pages(f"/appStoreVersionLocalizations/{lid}/appScreenshotSets")}
            for display, folder in SCREENSHOT_SLOTS:
                files = sorted(f for f in os.listdir(os.path.join(MK, folder)) if f.endswith(".png"))
                print(f"  {display:22} ← {folder}: {len(files)} files")
                if args.dry_run: continue
                s = sets.get(display)
                if s is None:
                    s = api("POST", "/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                        "attributes": {"screenshotDisplayType": display},
                        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}})["data"]
                for old in all_pages(f"/appScreenshotSets/{s['id']}/appScreenshots"):
                    api("DELETE", f"/appScreenshots/{old['id']}")
                ids = []
                for f in files:
                    ids.append(upload_asset("appScreenshots", "appScreenshotSet", s["id"], os.path.join(MK, folder, f)))
                    print(f"    uploaded {f}")
                api("PATCH", f"/appScreenshotSets/{s['id']}/relationships/appScreenshots",
                    {"data": [{"type": "appScreenshots", "id": i} for i in ids]})

        if do_prev:
            psets = {s["attributes"]["previewType"]: s
                     for s in all_pages(f"/appStoreVersionLocalizations/{lid}/appPreviewSets")}
            for ptype in PREVIEW_SLOTS:
                print(f"  preview {ptype:14} ← {PREVIEW_FILE} (poster {PREVIEW_POSTER})")
                if args.dry_run: continue
                s = psets.get(ptype)
                if s is None:
                    s = api("POST", "/appPreviewSets", {"data": {"type": "appPreviewSets",
                        "attributes": {"previewType": ptype},
                        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}})["data"]
                for old in all_pages(f"/appPreviewSets/{s['id']}/appPreviews"):
                    api("DELETE", f"/appPreviews/{old['id']}")
                upload_asset("appPreviews", "appPreviewSet", s["id"], os.path.join(MK, PREVIEW_FILE),
                             {"mimeType": "video/mp4", "previewFrameTimeCode": PREVIEW_POSTER})
                print("    uploaded (ASC processes previews asynchronously — check the version page in a few minutes)")

    print("\ndone" if not args.dry_run else "\ndry run — nothing changed")

if __name__ == "__main__":
    main()
