#!/usr/bin/env python3
"""One-time Gmail OAuth bootstrap (installed-app loopback flow, stdlib only).

Prints an accounts.google.com URL — open it in a browser on this machine,
consent as the benchmark Gmail account, and the loopback redirect completes
the exchange. Writes gmail-token.json next to the client config.
"""

import http.server
import json
import os
import secrets
import sys
import functools
print = functools.partial(print, flush=True)
import threading
import time
import urllib.parse
import urllib.request

from email_common import GMAIL_SCOPE, OAUTH_PATH, TOKEN_PATH

PORT = int(os.environ.get("BENCH_OAUTH_PORT", "8765"))
REDIRECT = f"http://localhost:{PORT}/"

code_holder: dict = {}
state = secrets.token_urlsafe(16)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if qs.get("state", [""])[0] != state:
            self.send_response(400)
            self.end_headers()
            return
        code_holder["code"] = qs.get("code", [""])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"fmsg-bench: authorised. You can close this tab.")

    def log_message(self, *args):
        pass


def main() -> int:
    with open(OAUTH_PATH) as f:
        oauth = json.load(f)

    params = urllib.parse.urlencode({
        "client_id": oauth["client_id"],
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "scope": GMAIL_SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
    })
    url = f"{oauth['auth_uri']}?{params}"

    server = http.server.HTTPServer(("localhost", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    print("Open this URL in a browser on this machine and authorise:")
    print()
    print(url)
    print()
    print(f"(waiting up to 10 minutes on {REDIRECT} ...)")

    deadline = time.time() + 600
    while "code" not in code_holder and time.time() < deadline:
        time.sleep(0.5)
    server.shutdown()

    if "code" not in code_holder:
        print("timed out waiting for authorisation", file=sys.stderr)
        return 1

    data = urllib.parse.urlencode({
        "client_id": oauth["client_id"],
        "client_secret": oauth["client_secret"],
        "code": code_holder["code"],
        "grant_type": "authorization_code",
        "redirect_uri": REDIRECT,
    }).encode()
    with urllib.request.urlopen(
            urllib.request.Request(oauth["token_uri"], data=data)) as resp:
        tok = json.load(resp)

    if "refresh_token" not in tok:
        print("no refresh_token in response — re-run (prompt=consent should force one)",
              file=sys.stderr)
        return 1

    with open(TOKEN_PATH, "w") as f:
        json.dump({
            "access_token": tok["access_token"],
            "refresh_token": tok["refresh_token"],
            "expires_at": time.time() + tok.get("expires_in", 3600),
        }, f)
    os.chmod(TOKEN_PATH, 0o600)
    print(f"token written to {TOKEN_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
