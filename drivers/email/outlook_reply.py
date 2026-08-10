#!/usr/bin/env python3
"""Act as the Outlook participant via Microsoft Graph: wait for a
message, optionally reply (reply-all with quoted history is Graph's
native reply behaviour).

  outlook_reply.py --tag "[m1p3x r1]" --wait-only
  outlook_reply.py --tag "[m1p3x r1]" --reply-body-file body.txt --reply-all
"""

import argparse
import sys
import time

import outlook_api
from email_common import print_json


def find_unread(tag: str, timeout: float, poll: float) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            out = outlook_api.api("GET", "/me/messages", {
                "$filter": "isRead eq false",
                "$top": "10",
                "$select": "id,subject",
            })
            for m in out.get("value", []):
                if tag in (m.get("subject") or ""):
                    return m
        except Exception as e:  # transient Graph/network errors
            print(f"outlook graph transient error, retrying: {e}", file=sys.stderr)
        time.sleep(poll)
    raise SystemExit(f"timed out waiting for unread message with tag {tag}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--wait-only", action="store_true")
    ap.add_argument("--reply-body-file")
    ap.add_argument("--reply-all", action="store_true")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--poll", type=float, default=3)
    args = ap.parse_args()

    msg = find_unread(args.tag, args.timeout, args.poll)
    outlook_api.api("PATCH", f"/me/messages/{msg['id']}", body={"isRead": True})

    if args.wait_only:
        print_json({"id": msg["id"]})
        return 0

    with open(args.reply_body_file) as f:
        reply_text = f.read()

    # Graph replyAll composes standard threading headers and quotes the
    # original below the comment, like a mail client.
    verb = "replyAll" if args.reply_all else "reply"
    outlook_api.api("POST", f"/me/messages/{msg['id']}/{verb}",
                    body={"comment": reply_text})
    print_json({"id": msg["id"], "replied": True})
    return 0


if __name__ == "__main__":
    sys.exit(main())
