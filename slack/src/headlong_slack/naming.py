"""Encode a Slack conversation into a chat `from` name and back.

The name is the only routing metadata that survives the round trip through
the mind log (`from` on the inbound message step comes back as `to` on the
reply step), so it has to carry everything needed to deliver the reply:

    DM:              slack-U07AB12CD-D09XYZ123
    channel/thread:  slack-U07AB12CD-C09XYZ123-1722400000.123456

Outbound, the mind also writes two short forms when it means "post in that
channel" or "DM that person" rather than "reply in this conversation":

    bare channel:    slack-C09XYZ123      (top-level post in the channel)
    bare user:       slack-U07AB12CD      (open the DM, post there)

The first letter of a Slack id says what it is: U and W are users, C public
channels, G private channels, D DM channels. That is what makes the two-part
forms unambiguous. See design/outbound_delivery.md.

It must match the web API's CHAT_FROM_RE (^[A-Za-z0-9][A-Za-z0-9._-]*$).
Slack IDs are alphanumeric and thread timestamps are digits.digits, so `-`
is a safe separator.

NAME_RE_TEXT is the single source of truth for the grammar. bin/chat carries
the same string (see _SLACK_NAME_RE there) and tests/test_naming.py asserts
the two are identical, so chat and the bridge cannot drift apart. Keep it in
the subset both Python `re` and bash ERE accept: plain groups, no `(?:`.
"""

from __future__ import annotations

import re
from typing import NamedTuple

PREFIX = "slack"

NAME_RE_TEXT = (
    r"^slack-([UW][A-Z0-9]+|[CGD][A-Z0-9]+|[A-Za-z0-9]+-[A-Za-z0-9]+(-[0-9.]+)?)$"
)
NAME_RE = re.compile(NAME_RE_TEXT)

ACCEPTED_FORMS = (
    "slack-<user>-<channel>-<thread ts> (reply in a channel thread), "
    "slack-<user>-<channel> (a DM, or a channel top-level), "
    "slack-C<id> (post top-level in a channel), "
    "slack-U<id> (DM a person)"
)


class Conversation(NamedTuple):
    user: str  # "" for a bare channel name
    channel: str  # "" for a bare user name (the DM is opened at delivery time)
    thread_ts: str | None  # None for DMs and top-level posts


def encode(user: str, channel: str, thread_ts: str | None = None) -> str:
    parts = [PREFIX, user, channel]
    if thread_ts is not None:
        parts.append(thread_ts)
    return "-".join(parts)


def decode(name: str) -> Conversation:
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ValueError(f"not a slack conversation name: {name!r}")
    parts = name.split("-")
    if len(parts) == 2:
        ident = parts[1]
        if ident[0] in "UW":
            return Conversation(ident, "", None)
        return Conversation("", ident, None)
    return Conversation(parts[1], parts[2], parts[3] if len(parts) == 4 else None)


def is_slack_name(name: object) -> bool:
    if not isinstance(name, str):
        return False
    try:
        decode(name)
    except ValueError:
        return False
    return True


def looks_like_slack(name: object) -> bool:
    """True for anything that claims to be a Slack name, valid or not.

    The bridge uses this to tell "ours, but malformed" (warn and write a
    failed delivery notice) from "another transport's" (skip silently).
    """
    return isinstance(name, str) and name.startswith(PREFIX + "-")
