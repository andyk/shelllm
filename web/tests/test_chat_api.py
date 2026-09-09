"""Chat conversation filter and PWA static-file route tests."""

import json
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from headlong_web import chat
from headlong_web.server import create_app

ROOT_TRAJ = "ffffffff-6666-4666-8666-666666666666"


def _msg(step_id: str, from_name: str, to_name: str, content: str, **extra) -> dict:
    return {
        "type": "message",
        "step_id": step_id,
        "from": from_name,
        "to": to_name,
        "content": content,
        "ts": f"t{step_id}",
        **extra,
    }


@pytest.fixture
def chat_identity(tmp_path: Path) -> Path:
    """Identity whose mind log mixes a pwa conversation with slack traffic."""
    identity = tmp_path / ".identities" / "chatty"
    identity.mkdir(parents=True)
    (identity / "info.txt").write_text(
        f"name=chatty\ncreated=2026-08-05T00:00:00\nroot_trajectory={ROOT_TRAJ}\n"
    )
    traj_dir = identity / "trajectories" / "ffffffff-root"
    traj_dir.mkdir(parents=True)
    steps = [
        {"type": "trajectory", "step_id": ROOT_TRAJ, "ts": "t0"},
        _msg("m1", "pwa-nick", "chatty", "hello from phone"),
        _msg("m2", "chatty", "pwa-nick", "hi nick", reply_to="m1"),
        _msg(
            "m3",
            "slack-U1-C1",
            "chatty",
            "slack says hi",
            source_url="https://laudesters.slack.com/archives/C1/p1788451200123456",
        ),
        _msg("m4", "chatty", "slack-U1-C1", "hi slack", reply_to="m3"),
        _msg("m5", "pwa-boss", "chatty", "boss checking in"),
        _msg("m6", "chatty", "pwa-boss", "hello boss", reply_to="m5"),
        _msg("m7", "pwa-nick", "chatty", "just an ack, thanks"),
        {
            "type": "observation",
            "step_id": "o1",
            "source": "monolith",
            "content": "Chose not to reply to pwa-nick — bare acknowledgment",
            "decision": "no-reply",
            "trigger_step": "m7",
            "ts": "to1",
        },
        _msg("m8", "pwa-boss", "chatty", "does this work?"),
        {
            "type": "observation",
            "step_id": "o2",
            "source": "monolith",
            "content": "reply failed: could not send a reply to pwa-boss",
            "trigger_step": "m8",
            "ts": "to2",
        },
    ]
    # Enough slack chatter that an unfiltered tail would push out the pwa
    # conversation — proves the filter runs before the tail slice.
    steps += [
        _msg(f"s{i}", "slack-U1-C1", "chatty", f"noise {i}") for i in range(50)
    ]
    (traj_dir / "trajectory.jsonl").write_text(
        "".join(json.dumps(s) + "\n" for s in steps)
    )
    return identity


@pytest.fixture
def client(chat_identity: Path) -> TestClient:
    return TestClient(create_app(chat_identity.parent.parent))


def test_chat_unfiltered_returns_all(client: TestClient):
    body = client.get("/api/identities/.identities~chatty/chat").json()
    froms = {m["from"] for m in body["messages"]}
    assert {"pwa-nick", "pwa-boss", "slack-U1-C1", "chatty"} <= froms


def test_chat_with_filters_conversation(client: TestClient):
    body = client.get(
        "/api/identities/.identities~chatty/chat", params={"with": "pwa-nick"}
    ).json()
    assert [m["step_id"] for m in body["messages"]] == ["m1", "m2", "m7"]
    for m in body["messages"]:
        assert "pwa-nick" in (m["from"], m["to"])


def test_chat_with_filter_applies_before_tail(client: TestClient):
    body = client.get(
        "/api/identities/.identities~chatty/chat",
        params={"with": "pwa-boss", "tail": 5},
    ).json()
    assert [m["step_id"] for m in body["messages"]] == ["m5", "m6", "m8"]


def test_chat_reply_to_surfaced(client: TestClient):
    body = client.get(
        "/api/identities/.identities~chatty/chat", params={"with": "pwa-nick"}
    ).json()
    by_id = {m["step_id"]: m for m in body["messages"]}
    assert by_id["m1"]["reply_to"] is None
    assert by_id["m2"]["reply_to"] == "m1"


def test_chat_slack_source_url_is_inherited_by_reply(client: TestClient):
    body = client.get("/api/identities/.identities~chatty/chat").json()
    by_id = {m["step_id"]: m for m in body["messages"]}
    expected = "https://laudesters.slack.com/archives/C1/p1788451200123456"
    assert by_id["m3"]["source_url"] == expected
    assert by_id["m4"]["source_url"] == expected
    assert by_id["m1"]["source_url"] is None


def test_chat_outcomes(client: TestClient):
    body = client.get(
        "/api/identities/.identities~chatty/chat", params={"with": "pwa-nick"}
    ).json()
    # m1 was replied to (m2 stamps reply_to), m7 was explicitly declined,
    # m8 hit a reply failure. Absent = still undecided.
    assert body["outcomes"]["m1"] == "replied"
    assert body["outcomes"]["m7"] == "no-reply"
    assert body["outcomes"]["m8"] == "failed"
    assert "s0" not in body["outcomes"]


def test_chat_includes_active_partial_reply(client: TestClient, chat_identity: Path):
    traj = chat_identity / "trajectories" / "ffffffff-root" / "trajectory.jsonl"
    unanswered = _msg("m9", "pwa-boss", "chatty", "are you there?")
    with traj.open("a") as stream:
        stream.write(json.dumps(unanswered) + "\n")
    partial = chat_identity / "run" / "responder-partials" / "m9"
    partial.mkdir(parents=True)
    (partial / "meta.json").write_text(
        json.dumps({"from": "chatty", "to": "pwa-boss", "reply_to": "m9"})
    )
    (partial / "content.txt").write_text("partial reply")

    body = client.get(
        "/api/identities/.identities~chatty/chat", params={"with": "pwa-boss"}
    ).json()

    last = body["messages"][-1]
    assert last == {
        "ts": None,
        "step_id": "partial:m9",
        "from": "chatty",
        "to": "pwa-boss",
        "content": "partial reply",
        "reply_to": "m9",
        "filename": None,
        "partial": True,
    }


def test_chat_view_omits_partial_after_final_outcome():
    partial = {
        "step_id": "partial:m10",
        "from": "chatty",
        "to": "pwa-boss",
        "content": "ghost",
        "reply_to": "m10",
        "filename": None,
        "partial": True,
    }
    view = chat.chat_view(
        [
            _msg("m10", "pwa-boss", "chatty", "question"),
            _msg("m11", "chatty", "pwa-boss", "answer", reply_to="m10"),
        ],
        "chatty",
        partials=[partial],
    )

    assert [message["step_id"] for message in view["messages"]] == ["m10", "m11"]


def test_chat_view_keeps_partial_after_failed_outcome():
    partial = {
        "step_id": "partial:m10",
        "from": "chatty",
        "to": "pwa-boss",
        "content": "retry draft",
        "reply_to": "m10",
        "filename": None,
        "partial": True,
    }
    view = chat.chat_view(
        [
            _msg("m10", "pwa-boss", "chatty", "question"),
            {
                "type": "observation",
                "step_id": "o10",
                "content": "reply failed: transport error",
                "trigger_step": "m10",
            },
        ],
        "chatty",
        partials=[partial],
    )

    assert [message["step_id"] for message in view["messages"]] == [
        "m10",
        "partial:m10",
    ]


def test_active_partial_replies_ignores_invalid_entries(tmp_path: Path):
    identity = tmp_path / ".identities" / "chatty"
    partials_root = identity / "run" / "responder-partials"
    partials_root.mkdir(parents=True)
    (partials_root / "not-a-dir").write_text("ignored")
    stale = partials_root / "stale"
    stale.mkdir()
    (stale / "meta.json").write_text(json.dumps({"from": "chatty", "to": "pwa-boss"}))
    stale_content = stale / "content.txt"
    stale_content.write_text("too old")
    os.utime(stale_content, (1, 1))
    malformed = partials_root / "malformed"
    malformed.mkdir()
    (malformed / "meta.json").write_text("{")
    (malformed / "content.txt").write_text("bad meta")
    empty = partials_root / "empty"
    empty.mkdir()
    (empty / "meta.json").write_text(json.dumps({"from": "chatty", "to": "pwa-boss"}))
    (empty / "content.txt").write_text("")

    assert chat.active_partial_replies(identity, "chatty", now=400) == []


def test_active_partial_replies_filters_and_uses_defaults(tmp_path: Path):
    identity = tmp_path / ".identities" / "chatty"
    current = identity / "run" / "responder-partials" / "m12"
    current.mkdir(parents=True)
    (current / "meta.json").write_text(json.dumps({}))
    (current / "content.txt").write_text("draft")

    assert chat.active_partial_replies(identity, "chatty", with_name="someone") == []
    assert chat.active_partial_replies(identity, "chatty", with_name="chatty") == [
        {
            "ts": None,
            "step_id": "partial:m12",
            "from": "chatty",
            "to": "",
            "content": "draft",
            "reply_to": "m12",
            "filename": None,
            "partial": True,
        }
    ]


def test_active_partial_replies_tolerates_partial_utf8_write(tmp_path: Path):
    identity = tmp_path / ".identities" / "chatty"
    current = identity / "run" / "responder-partials" / "m13"
    current.mkdir(parents=True)
    (current / "meta.json").write_text(
        json.dumps({"from": "chatty", "to": "pwa-boss", "reply_to": "m13"})
    )
    (current / "content.txt").write_bytes(b"hello \xe2")

    [partial] = chat.active_partial_replies(identity, "chatty", with_name="pwa-boss")

    assert partial["content"] == "hello \ufffd"


def test_active_partial_replies_missing_root_returns_empty(tmp_path: Path):
    assert chat.active_partial_replies(tmp_path / ".identities" / "chatty", "chatty") == []


def test_chat_with_rejects_bad_name(client: TestClient):
    resp = client.get(
        "/api/identities/.identities~chatty/chat", params={"with": "no spaces"}
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# PWA static routes: must serve real bytes, not the SPA catch-all's index.html
# ---------------------------------------------------------------------------


@pytest.fixture
def static_client(chat_identity: Path, tmp_path: Path) -> TestClient:
    static = tmp_path / "static"
    (static / "icons").mkdir(parents=True)
    (static / "index.html").write_text("<html>spa</html>")
    (static / "manifest.webmanifest").write_text('{"name": "Audel"}')
    (static / "sw.js").write_text("// sw")
    (static / "icons" / "icon-192.png").write_bytes(b"\x89PNG192")
    (static / "icons" / "apple-touch-icon.png").write_bytes(b"\x89PNGapple")
    return TestClient(create_app(chat_identity.parent.parent, static))


def test_manifest_served_with_type(static_client: TestClient):
    resp = static_client.get("/manifest.webmanifest")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("application/manifest+json")
    assert resp.json()["name"] == "Audel"


def test_service_worker_served_from_root(static_client: TestClient):
    resp = static_client.get("/sw.js")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/javascript")
    assert resp.text == "// sw"


def test_icons_served(static_client: TestClient):
    resp = static_client.get("/icons/icon-192.png")
    assert resp.status_code == 200
    assert resp.content == b"\x89PNG192"
    assert static_client.get("/apple-touch-icon.png").content == b"\x89PNGapple"


def test_icon_traversal_and_missing_404(static_client: TestClient):
    # Traversal paths normalize away before routing and land on the SPA
    # catch-all, never the icon route; bad names and non-png 404.
    assert static_client.get("/icons/../index.html").text == "<html>spa</html>"
    assert static_client.get("/icons/nope.png").status_code == 404
    assert static_client.get("/icons/evil.js").status_code == 404


def test_spa_catch_all_still_works(static_client: TestClient):
    resp = static_client.get("/talk")
    assert resp.text == "<html>spa</html>"
