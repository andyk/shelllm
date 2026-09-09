import pathlib
import re

import pytest

from headlong_slack import naming

# Mirrors CHAT_FROM_RE in web/src/headlong_web/safety.py — the web API rejects
# from_name values that don't match, so every encoded key must pass.
CHAT_FROM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def test_dm_round_trip():
    name = naming.encode("U07AB12CD", "D09XYZ123")
    assert name == "slack-U07AB12CD-D09XYZ123"
    assert CHAT_FROM_RE.match(name)
    assert naming.decode(name) == ("U07AB12CD", "D09XYZ123", None)


def test_thread_round_trip():
    name = naming.encode("U07AB12CD", "C09XYZ123", "1722400000.123456")
    assert name == "slack-U07AB12CD-C09XYZ123-1722400000.123456"
    assert CHAT_FROM_RE.match(name)
    assert naming.decode(name) == ("U07AB12CD", "C09XYZ123", "1722400000.123456")


def test_is_slack_name():
    assert naming.is_slack_name("slack-U1-C2-3.4")
    assert naming.is_slack_name("slack-U1-D2")
    assert not naming.is_slack_name("nick")
    assert not naming.is_slack_name("slack--C2-3.4")
    assert not naming.is_slack_name("slack-")
    assert not naming.is_slack_name("slack-...")
    assert not naming.is_slack_name(None)
    assert not naming.is_slack_name(42)


def test_bare_channel_and_user_forms():
    """The mind writes slack-C… for "post in that channel" and slack-U… for
    "DM that person". Both were silently dropped until 2026-09-09."""
    assert naming.decode("slack-C0BMVH6LM4K") == ("", "C0BMVH6LM4K", None)
    assert naming.decode("slack-G0BMVH6LM4K") == ("", "G0BMVH6LM4K", None)
    assert naming.decode("slack-D0BMVH6LM4K") == ("", "D0BMVH6LM4K", None)
    assert naming.decode("slack-U0BFD9NDVE3") == ("U0BFD9NDVE3", "", None)
    assert naming.decode("slack-W0BFD9NDVE3") == ("W0BFD9NDVE3", "", None)
    # Only real Slack id shapes qualify for the short forms.
    assert not naming.is_slack_name("slack-nick")
    assert not naming.is_slack_name("slack-x1")
    assert not naming.is_slack_name("slack-c0bmvh6lm4k")


def test_looks_like_slack():
    assert naming.looks_like_slack("slack-bogus")
    assert naming.looks_like_slack("slack-U1-C2")
    assert not naming.looks_like_slack("telegram-1")
    assert not naming.looks_like_slack(None)


def test_chat_carries_the_same_grammar():
    """bin/chat validates Slack targets with a copy of NAME_RE_TEXT. This is
    the check that keeps chat and the bridge from drifting apart: change one
    without the other and this fails (design/outbound_delivery.md, part 1)."""
    chat = pathlib.Path(__file__).resolve().parents[2] / "bin" / "chat"
    lines = [l for l in chat.read_text().splitlines() if l.startswith("_SLACK_NAME_RE=")]
    assert len(lines) == 1, "bin/chat must define _SLACK_NAME_RE exactly once"
    value = lines[0].split("=", 1)[1].strip()
    assert value.startswith("'") and value.endswith("'"), "quote the regex with single quotes"
    assert value[1:-1] == naming.NAME_RE_TEXT
    # The shared text must stay in the subset bash ERE accepts.
    assert "(?:" not in naming.NAME_RE_TEXT


def test_decode_rejects_garbage():
    with pytest.raises(ValueError):
        naming.decode("telegram-U1-C2")
    with pytest.raises(ValueError):
        naming.decode("slack-U1-C2-3.4-extra")
