"""Shared helpers for the email driver. Stdlib only.

Credentials come from ~/.config/fmsg-bench/email.env and the Gmail OAuth
files next to it — never from the repo, and never written into results.
"""

import email
import email.policy
import json
import os
import sys

CONFIG_DIR = os.path.expanduser("~/.config/fmsg-bench")
ENV_PATH = os.path.join(CONFIG_DIR, "email.env")
OAUTH_PATH = os.path.join(CONFIG_DIR, "gmail-oauth.json")
TOKEN_PATH = os.path.join(CONFIG_DIR, "gmail-token.json")

GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.modify"


def load_env() -> dict:
    env = {}
    with open(ENV_PATH) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    return env


def body_text_of(msg: email.message.Message) -> str:
    """Extract the text/plain body of a parsed email message."""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                return part.get_content()
    else:
        if msg.get_content_type() == "text/plain":
            return msg.get_content()
    return ""


def quote_body(sender_label: str, date_str: str, body: str) -> str:
    """Standard reply quoting: attribution line + '> ' prefixed lines."""
    quoted = "\n".join("> " + line for line in body.splitlines())
    return f"On {date_str}, {sender_label} wrote:\n{quoted}"


def print_json(obj) -> None:
    json.dump(obj, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
