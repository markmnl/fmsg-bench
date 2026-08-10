#!/usr/bin/env python3
"""Submit a message from the local (mailcow) side via the SSH tunnel.

  send.py --to a@x [--to b@x ...] --subject S --body-file F
          [--attach path] [--reply-json waitresult.json]

Submission goes to 127.0.0.1:$BENCH_TUNNEL_SMTP_PORT (STARTTLS) — this
client->server leg is deliberately NOT part of the measured capture,
which sees only host-to-host port 25. With --reply-json (the JSON that
imap_wait.py printed for the message being replied to) the mail gets
Re:, In-Reply-To/References and the quoted previous body, like a mail
client reply. Prints JSON {"message_id": ...}.
"""

import argparse
import email.utils
import json
import mimetypes
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

from email_common import load_env, print_json, quote_body


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--to", action="append", required=True)
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--attach")
    ap.add_argument("--reply-json")
    ap.add_argument("--account", type=int, default=1,
                    help="local persona: 1 -> BENCH_LOCAL_*, 2 -> BENCH_LOCAL2_*")
    args = ap.parse_args()

    env = load_env()
    prefix = "BENCH_LOCAL_" if args.account == 1 else f"BENCH_LOCAL{args.account}_"
    local = env[prefix + "ADDR"]
    port = int(env.get("BENCH_TUNNEL_SMTP_PORT", "15870"))

    with open(args.body_file) as f:
        body = f.read()

    msg = EmailMessage()
    msg["From"] = local
    msg["To"] = ", ".join(args.to)
    msg["Subject"] = args.subject
    msg["Date"] = email.utils.formatdate(localtime=True)
    msg["Message-ID"] = email.utils.make_msgid(domain=local.split("@", 1)[1])

    if args.reply_json:
        with open(args.reply_json) as f:
            prev = json.load(f)
        if prev.get("message_id"):
            msg["In-Reply-To"] = prev["message_id"]
            msg["References"] = (prev.get("references", "") + " " + prev["message_id"]).strip()
        body = body + "\n\n" + quote_body(
            prev.get("from", "remote"), prev.get("date", ""), prev.get("body", ""))

    msg.set_content(body)

    if args.attach:
        ctype = mimetypes.guess_type(args.attach)[0] or "application/octet-stream"
        maintype, subtype = ctype.split("/", 1)
        with open(args.attach, "rb") as f:
            msg.add_attachment(f.read(), maintype=maintype, subtype=subtype,
                               filename=os.path.basename(args.attach))

    ctx = ssl.create_default_context()
    ctx.check_hostname = False          # tunnel endpoint is 127.0.0.1
    ctx.verify_mode = ssl.CERT_NONE
    s = smtplib.SMTP("127.0.0.1", port, timeout=30)
    s.ehlo()
    s.starttls(context=ctx)
    s.ehlo()
    s.login(local, env[prefix + "PASS"])
    s.send_message(msg)
    s.quit()

    print_json({"message_id": msg["Message-ID"]})
    return 0


if __name__ == "__main__":
    sys.exit(main())
