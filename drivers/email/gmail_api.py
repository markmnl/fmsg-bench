"""Minimal Gmail REST client, stdlib only (no google-api-python-client).

Token management: gmail-token.json holds {access_token, refresh_token,
expires_at}. Access tokens auto-refresh via the OAuth token endpoint.
"""

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from email_common import OAUTH_PATH, TOKEN_PATH

API_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"


def _load(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _save_token(tok: dict) -> None:
    with open(TOKEN_PATH, "w") as f:
        json.dump(tok, f)
    os.chmod(TOKEN_PATH, 0o600)


def access_token() -> str:
    if not os.path.exists(TOKEN_PATH):
        raise SystemExit(
            f"no Gmail token at {TOKEN_PATH} — run gmail_oauth_bootstrap.py first")
    tok = _load(TOKEN_PATH)
    if tok.get("expires_at", 0) > time.time() + 60:
        return tok["access_token"]

    oauth = _load(OAUTH_PATH)
    data = urllib.parse.urlencode({
        "client_id": oauth["client_id"],
        "client_secret": oauth["client_secret"],
        "refresh_token": tok["refresh_token"],
        "grant_type": "refresh_token",
    }).encode()
    with urllib.request.urlopen(
            urllib.request.Request(oauth["token_uri"], data=data)) as resp:
        fresh = json.load(resp)
    tok["access_token"] = fresh["access_token"]
    tok["expires_at"] = time.time() + fresh.get("expires_in", 3600)
    _save_token(tok)
    return tok["access_token"]


def api(method: str, path: str, params: dict | None = None, body: dict | None = None) -> dict:
    url = API_BASE + path
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


def list_messages(query: str, max_results: int = 10) -> list[dict]:
    out = api("GET", "/messages", {"q": query, "maxResults": max_results})
    return out.get("messages", [])


def get_message(msg_id: str, fmt: str = "full") -> dict:
    return api("GET", f"/messages/{msg_id}", {"format": fmt})


def send_raw(raw_message: bytes, thread_id: str | None = None) -> dict:
    body = {"raw": base64.urlsafe_b64encode(raw_message).decode()}
    if thread_id:
        body["threadId"] = thread_id
    return api("POST", "/messages/send", body=body)


def mark_read(msg_id: str) -> None:
    api("POST", f"/messages/{msg_id}/modify", body={"removeLabelIds": ["UNREAD"]})
