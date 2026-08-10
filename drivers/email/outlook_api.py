"""Minimal Microsoft Graph mail client, stdlib only.

Consumer (personal) accounts via device-code flow. Token cache:
~/.config/fmsg-bench/outlook-token.json. Config in email.env:
  BENCH_OUTLOOK_ADDR=you@outlook.com
  BENCH_OUTLOOK_CLIENT_ID=<app registration client id>
"""

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from email_common import CONFIG_DIR, load_env

TOKEN_PATH = os.path.join(CONFIG_DIR, "outlook-token.json")
AUTHORITY = "https://login.microsoftonline.com/consumers"
SCOPES = "Mail.ReadWrite Mail.Send offline_access"
GRAPH = "https://graph.microsoft.com/v1.0"


def _save(tok: dict) -> None:
    with open(TOKEN_PATH, "w") as f:
        json.dump(tok, f)
    os.chmod(TOKEN_PATH, 0o600)


def _post_form(url: str, data: dict) -> dict:
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode())
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        return json.loads(e.read())


def device_code_login() -> None:
    env = load_env()
    client_id = env["BENCH_OUTLOOK_CLIENT_ID"]
    dc = _post_form(f"{AUTHORITY}/oauth2/v2.0/devicecode",
                    {"client_id": client_id, "scope": SCOPES})
    if "user_code" not in dc:
        raise SystemExit(f"device code request failed: {dc}")
    print(dc["message"], flush=True)
    deadline = time.time() + dc.get("expires_in", 900)
    while time.time() < deadline:
        time.sleep(dc.get("interval", 5))
        tok = _post_form(f"{AUTHORITY}/oauth2/v2.0/token", {
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": client_id,
            "device_code": dc["device_code"],
        })
        if "access_token" in tok:
            tok["expires_at"] = time.time() + tok.get("expires_in", 3600)
            _save(tok)
            print(f"token written to {TOKEN_PATH}", flush=True)
            return
        if tok.get("error") not in ("authorization_pending", "slow_down"):
            raise SystemExit(f"login failed: {tok}")
    raise SystemExit("timed out waiting for device-code login")


def access_token() -> str:
    if not os.path.exists(TOKEN_PATH):
        raise SystemExit(f"no Outlook token at {TOKEN_PATH} — run outlook_api.py to log in")
    with open(TOKEN_PATH) as f:
        tok = json.load(f)
    if tok.get("expires_at", 0) > time.time() + 60:
        return tok["access_token"]
    env = load_env()
    fresh = _post_form(f"{AUTHORITY}/oauth2/v2.0/token", {
        "grant_type": "refresh_token",
        "client_id": env["BENCH_OUTLOOK_CLIENT_ID"],
        "refresh_token": tok["refresh_token"],
        "scope": SCOPES,
    })
    if "access_token" not in fresh:
        raise SystemExit(f"token refresh failed: {fresh}")
    fresh["expires_at"] = time.time() + fresh.get("expires_in", 3600)
    if "refresh_token" not in fresh:
        fresh["refresh_token"] = tok["refresh_token"]
    _save(fresh)
    return fresh["access_token"]


def api(method: str, path: str, params: dict | None = None, body: dict | None = None) -> dict:
    url = GRAPH + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", "Bearer " + access_token())
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data) as resp:
        payload = resp.read()
    return json.loads(payload) if payload else {}


if __name__ == "__main__":
    device_code_login()
