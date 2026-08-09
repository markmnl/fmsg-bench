#!/usr/bin/env python3
"""Act as the remote (Gmail) participant: wait for a message, optionally reply.

  gmail_reply.py --tag "[m3p2 r1]" --wait-only
  gmail_reply.py --tag "[m3p2 r1]" --reply-body-file body.txt
  gmail_reply.py --reply-to-id <gmail-id> --reply-body-file body.txt

Waits for an UNREAD message whose subject contains the tag, then (unless
--wait-only) sends a reply built the way a mail client would: Re: subject,
In-Reply-To/References headers, and the full previous body quoted with
'> ' below an attribution line — so quoted history accumulates naturally
over a conversation. Marks processed messages read. Prints JSON.

--reply-to-id skips the wait and replies to a specific message: used for
branch scenarios (second reply to the same parent) and consecutive
remote turns (the account replying to its own previous reply).
"""

import argparse
import email
import email.policy
import email.utils
import sys
import time
from email.message import EmailMessage

import gmail_api
from email_common import body_text_of, load_env, print_json, quote_body


def find_unread(tag: str, timeout: float, poll: float) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        # in:anywhere: repetitive benchmark mail can get spam-foldered and
        # the default search silently excludes spam — blinding the responder.
        for m in gmail_api.list_messages(f'subject:"{tag}" is:unread in:anywhere', 5):
            return gmail_api.get_message(m["id"], "raw")
        time.sleep(poll)
    raise SystemExit(f"timed out waiting for unread message with tag {tag}")


def parse_raw(msg: dict) -> email.message.EmailMessage:
    import base64
    raw = base64.urlsafe_b64decode(msg["raw"])
    return email.message_from_bytes(raw, policy=email.policy.default)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag")
    ap.add_argument("--wait-only", action="store_true")
    ap.add_argument("--reply-body-file")
    ap.add_argument("--reply-to-id",
                    help="skip waiting; reply directly to this Gmail message id "
                         "(consecutive remote turns / branch replies)")
    ap.add_argument("--reply-all", action="store_true")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--poll", type=float, default=2)
    args = ap.parse_args()

    env = load_env()
    self_addr = env["BENCH_REMOTE_ADDR"]

    if args.reply_to_id:
        found = gmail_api.get_message(args.reply_to_id, "raw")
    else:
        if not args.tag:
            raise SystemExit("--tag is required unless --reply-to-id is given")
        found = find_unread(args.tag, args.timeout, args.poll)
        gmail_api.mark_read(found["id"])

    if args.wait_only:
        print_json({"id": found["id"], "threadId": found.get("threadId")})
        return 0

    target = found

    parsed = parse_raw(target)
    orig_from = parsed["From"]
    orig_date = parsed["Date"] or email.utils.formatdate()
    orig_body = body_text_of(parsed)
    orig_msgid = parsed["Message-ID"] or ""
    orig_refs = parsed["References"] or ""
    subject = parsed["Subject"] or args.tag
    if not subject.lower().startswith("re:"):
        subject = "Re: " + subject

    with open(args.reply_body_file) as f:
        reply_text = f.read()

    reply = EmailMessage()
    reply["From"] = self_addr
    to = [email.utils.parseaddr(orig_from)[1]]
    if args.reply_all:
        for _, addr in email.utils.getaddresses(parsed.get_all("To", [])):
            if addr and addr.lower() != self_addr.lower():
                to.append(addr)
    reply["To"] = ", ".join(dict.fromkeys(to))
    reply["Subject"] = subject
    if orig_msgid:
        reply["In-Reply-To"] = orig_msgid
        reply["References"] = (orig_refs + " " + orig_msgid).strip()
    sender_label = email.utils.parseaddr(orig_from)[1]
    reply.set_content(reply_text + "\n\n" + quote_body(sender_label, orig_date, orig_body))

    sent = gmail_api.send_raw(reply.as_bytes(), thread_id=found.get("threadId"))
    print_json({"id": found["id"], "sent_id": sent.get("id"),
                "threadId": sent.get("threadId")})
    return 0


if __name__ == "__main__":
    sys.exit(main())
