#!/usr/bin/env python3
"""Wait for a message to arrive in the local (mailcow) INBOX via the tunnel.

  imap_wait.py --tag "[m3p2 r1]" [--count 1] [--timeout 300]

Polls for UNSEEN messages whose subject contains the tag; on match marks
them seen and prints one JSON line each: {message_id, references, from,
date, subject, body} — the input send.py needs to build a quoted reply.
"""

import argparse
import email
import email.policy
import imaplib
import ssl
import sys
import time

from email_common import body_text_of, load_env, print_json


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--poll", type=float, default=1)
    args = ap.parse_args()

    env = load_env()
    port = int(env.get("BENCH_TUNNEL_IMAP_PORT", "19930"))

    ctx = ssl.create_default_context()
    ctx.check_hostname = False          # tunnel endpoint is 127.0.0.1
    ctx.verify_mode = ssl.CERT_NONE

    matched = 0
    deadline = time.time() + args.timeout
    while time.time() < deadline and matched < args.count:
        imap = imaplib.IMAP4_SSL("127.0.0.1", port, ssl_context=ctx)
        imap.login(env["BENCH_LOCAL_ADDR"], env["BENCH_LOCAL_PASS"])
        imap.select("INBOX")
        typ, data = imap.search(None, "UNSEEN", "SUBJECT", f'"{args.tag}"')
        if typ == "OK" and data and data[0]:
            for num in data[0].split():
                typ, fetched = imap.fetch(num, "(RFC822)")
                if typ != "OK":
                    continue
                # fetch() responses interleave untagged items on a busy
                # mailbox; find the literal (bytes) part rather than
                # assuming fetched[0][1].
                raw = next((item[1] for item in fetched
                            if isinstance(item, tuple) and len(item) > 1
                            and isinstance(item[1], (bytes, bytearray))), None)
                if raw is None:
                    continue
                msg = email.message_from_bytes(raw, policy=email.policy.default)
                imap.store(num, "+FLAGS", "\\Seen")
                print_json({
                    "message_id": msg["Message-ID"] or "",
                    "references": msg["References"] or "",
                    "from": email.utils.parseaddr(msg["From"] or "")[1],
                    "date": msg["Date"] or "",
                    "subject": msg["Subject"] or "",
                    "body": body_text_of(msg),
                })
                matched += 1
                if matched >= args.count:
                    break
        imap.logout()
        if matched < args.count:
            time.sleep(args.poll)

    if matched < args.count:
        print(f"timed out: {matched}/{args.count} messages with tag {args.tag}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
