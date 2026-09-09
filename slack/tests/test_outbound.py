"""Outbound filter: only bin/chat speaks for the identity."""

import base64
import threading

from headlong_slack import outbound
from headlong_slack.config import Config


def _cfg(tmp_path):
    return Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", app_token="x", web_url="http://x", state_dir=tmp_path,
        thread_followups=True,
    )


def test_run_delivers_only_chat_sourced_messages(tmp_path, monkeypatch):
    """Message steps without source:"chat" (a thinker appending raw message
    steps to the trajectory) must not reach Slack."""
    steps = [
        {"type": "message", "from": "audel", "to": "slack-C1-U1",
         "source": "chat", "content": "real reply", "step_id": "aaa"},
        {"type": "message", "from": "audel", "to": "slack-C1-U1",
         "source": "responder", "content": "forged reply", "step_id": "bbb"},
        {"type": "message", "from": "audel", "to": "slack-C1-U1",
         "content": "unstamped reply", "step_id": "ccc"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert sent == ["real reply"]


def test_text_file_uploads_via_files_upload_v2(tmp_path, monkeypatch):
    """chat send-file stamps filename + content_b64; Slack must upload, not post."""
    body = b"hello file\n"
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt",
         "content": "hello file",
         "content_b64": base64.b64encode(body).decode("ascii"),
         "step_id": "fff"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    uploads = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def files_upload_v2(self, **kw):
            uploads.append(kw)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert sent == []
    assert len(uploads) == 1
    assert uploads[0]["filename"] == "note.txt"
    assert uploads[0]["content"] == body
    assert uploads[0]["channel"] == "C1"
    assert "thread_ts" not in uploads[0]


def test_png_uploads_bytes_in_thread(tmp_path, monkeypatch):
    png = b"\x89PNG\r\n\x1a\n" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C09XYZ-1722400000.123456",
         "source": "chat", "filename": "fig.png",
         "content": "[file: fig.png]",
         "content_b64": base64.b64encode(png).decode("ascii"),
         "step_id": "png"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    uploads = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def files_upload_v2(self, **kw):
            uploads.append(kw)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert sent == []
    assert uploads[0]["content"] == png
    assert uploads[0]["filename"] == "fig.png"
    assert uploads[0]["channel"] == "C09XYZ"
    assert uploads[0]["thread_ts"] == "1722400000.123456"


def test_file_upload_failure_falls_back_to_notice(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "fail"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def files_upload_v2(self, **kw):
            raise RuntimeError("upload rejected")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert sent == ["(failed to deliver file note.txt)"]


def test_undecodable_file_falls_back_to_notice(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt",
         "content": "[file: note.txt]", "content_b64": "@@@bad@@@",
         "step_id": "bad"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    uploads = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def files_upload_v2(self, **kw):
            uploads.append(kw)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert uploads == []
    assert sent == ["(failed to deliver file note.txt)"]



def test_file_upload_retries_after_slack_rejects_first_identical_step(tmp_path, monkeypatch):
    """Do not suppress a retry after Slack rejects the first upload.

    recent.seen/record must not stamp the file signature until files_upload_v2
    succeeds. Otherwise a transient Slack failure plus a repeated chat send-file
    step posts one notice and skips the second attempt for five minutes.
    """
    raw = b"same-bytes"
    b64 = base64.b64encode(raw).decode("ascii")
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "a"},
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "b"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    uploads = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def files_upload_v2(self, **kw):
            uploads.append(kw["content"])
            if len(uploads) == 1:
                raise RuntimeError("upload rejected")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert uploads == [raw, raw]
    assert sent == ["(failed to deliver file note.txt)"]


def test_identical_file_steps_are_suppressed(tmp_path, monkeypatch):
    raw = b"same-bytes"
    b64 = base64.b64encode(raw).decode("ascii")
    other = b"other-bytes"
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "a"},
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "b"},
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt",
         "content_b64": base64.b64encode(other).decode("ascii"),
         "step_id": "c"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    uploads = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            raise AssertionError("no text fallback")

        def files_upload_v2(self, **kw):
            uploads.append(kw["content"])

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert uploads == [raw, other]


def test_invalid_file_content_does_not_stop_later_replies(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "bad.bin",
         "content": {"x": "y"}, "step_id": "bad"},
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "content": "later reply", "step_id": "ok"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def files_upload_v2(self, **kw):
            raise AssertionError("should not upload")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert sent == ["(failed to deliver file bad.bin)", "later reply"]


def test_client_without_upload_posts_notice(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-C1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "n"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert sent == ["(failed to deliver file note.txt)"]


def test_message_ts_from_source_url():
    parse = outbound.message_ts_from_source_url
    assert parse(
        "https://laudesters.slack.com/archives/C123/p1788451200123456"
    ) == "1788451200.123456"
    assert parse("https://slack.com/archives/C1/p12345678") == "12.345678"
    assert parse("https://example.com/archives/C123/p1788451200123456") == "1788451200.123456"
    assert parse("not-a-url") is None
    assert parse("") is None
    assert parse(None) is None
    assert parse("https://slack.com/archives/C123") is None
    assert parse("https://slack.com/files/C123/p1788451200123456") is None


def test_reaction_name_strips_colons():
    assert outbound.reaction_name({"reaction": "thumbsup"}) == "thumbsup"
    assert outbound.reaction_name({"reaction": ":eyes:"}) == "eyes"
    assert outbound.reaction_name({"reaction": "+1"}) == "+1"
    assert outbound.reaction_name({"reaction": "thumbsup::skin-tone-2"}) == "thumbsup::skin-tone-2"
    assert outbound.reaction_name({"reaction": "not a name"}) is None
    assert outbound.reaction_name({"reaction": ""}) is None
    assert outbound.reaction_name({"content": ":eyes:"}) is None


def test_reaction_step_calls_reactions_add(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1722400000.123456",
         "source": "chat", "reaction": "thumbsup", "content": ":thumbsup:",
         "source_url": "https://laudesters.slack.com/archives/C1/p1722400000123456",
         "step_id": "r1"},
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1722400000.123456",
         "source": "chat", "content": "text after", "step_id": "t1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []
    sent = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def reactions_add(self, channel, timestamp, name):
            added.append((channel, timestamp, name))

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert added == [("C1", "1722400000.123456", "thumbsup")]
    assert sent == ["text after"]


def test_reaction_falls_back_to_thread_ts_without_permalink(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1722400000.123456",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "r1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []

    class FakeClient:
        def chat_postMessage(self, **kw):
            raise AssertionError("reaction must not post text")

        def reactions_add(self, channel, timestamp, name):
            added.append((channel, timestamp, name))

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert added == [("C1", "1722400000.123456", "eyes")]


def test_dm_reaction_without_permalink_is_skipped(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "slack-U1-D1",
         "source": "chat", "reaction": "thumbsup", "content": ":thumbsup:",
         "step_id": "r1"},
        {"type": "message", "from": "audel", "to": "slack-U1-D1",
         "source": "chat", "content": "later", "step_id": "t1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []
    sent = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            sent.append(text)

        def reactions_add(self, **kw):
            added.append(kw)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert added == []
    assert sent == ["later"]


def test_identical_reactions_are_suppressed(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "a"},
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "b"},
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "thumbsup", "content": ":thumbsup:",
         "step_id": "c"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []

    class FakeClient:
        def chat_postMessage(self, **kw):
            raise AssertionError("no text")

        def reactions_add(self, channel, timestamp, name):
            added.append(name)

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert added == ["eyes", "thumbsup"]


def test_failed_reaction_is_not_recorded_so_retry_works(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "a"},
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "b"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []

    class FakeClient:
        def chat_postMessage(self, **kw):
            raise AssertionError("no text")

        def reactions_add(self, channel, timestamp, name):
            added.append(name)
            if len(added) == 1:
                raise RuntimeError("transient")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert added == ["eyes", "eyes"]


def test_already_reacted_counts_as_success(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "a"},
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "chat", "reaction": "eyes", "content": ":eyes:",
         "step_id": "b"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []

    class Already(Exception):
        response = {"error": "already_reacted"}

    class FakeClient:
        def chat_postMessage(self, **kw):
            raise AssertionError("no text")

        def reactions_add(self, channel, timestamp, name):
            added.append(name)
            raise Already("already_reacted")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    # first already_reacted is success -> recorded; second is suppressed
    assert added == ["eyes"]


def test_forged_reaction_without_chat_source_is_ignored(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel",
         "to": "slack-U1-C1-1.1",
         "source": "responder", "reaction": "eyes", "content": ":eyes:",
         "step_id": "forged"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    added = []

    class FakeClient:
        def reactions_add(self, **kw):
            added.append(kw)

        def chat_postMessage(self, **kw):
            raise AssertionError("no text")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), FakeClient(), FakeThreads(), threading.Event())
    assert added == []


# --- delivery notices and the short address forms (design/outbound_delivery.md)

def _drive(tmp_path, monkeypatch, steps, client):
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    outbound.run(_cfg(tmp_path), client, FakeThreads(), threading.Event())


class RecordingClient:
    """A Slack client that answers like slack_sdk does: postMessage returns
    a ts, conversations.open returns a DM channel, getPermalink a link."""

    def __init__(self, fail_post=False):
        self.posts = []
        self.opened = []
        self.fail_post = fail_post

    def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
        if self.fail_post:
            raise RuntimeError("channel_not_found")
        self.posts.append({"channel": channel, "thread_ts": thread_ts, "text": text})
        return {"ok": True, "ts": f"1757372480.{len(self.posts):06d}"}

    def conversations_open(self, users):
        self.opened.append(users)
        return {"ok": True, "channel": {"id": f"D-{users}"}}

    def chat_getPermalink(self, channel, message_ts):
        return {"ok": True, "permalink": f"https://x.slack.com/archives/{channel}/p{message_ts.replace('.', '')}"}


def _msg(step_id, to, content="hello"):
    return {"type": "message", "from": "audel", "to": to, "source": "chat",
            "content": content, "step_id": step_id}


def test_bare_channel_posts_top_level_and_is_confirmed(tmp_path, monkeypatch, notices):
    client = RecordingClient()
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-C0BMVH6LM4K", "papers")], client)
    assert client.posts == [{"channel": "C0BMVH6LM4K", "thread_ts": None, "text": "papers"}]
    assert client.opened == []
    assert len(notices) == 1
    n = notices[0]
    assert n["type"] == "delivery" and n["source"] == "slack-bridge" and n["transport"] == "slack"
    assert n["status"] == "delivered" and n["trigger_step"] == "m1" and n["to"] == "slack-C0BMVH6LM4K"
    assert n["channel"] == "C0BMVH6LM4K" and n["ts"] == "1757372480.000001"
    assert n["permalink"].endswith("/archives/C0BMVH6LM4K/p1757372480000001")
    assert n["content"] == "delivered to slack-C0BMVH6LM4K"


def test_bare_user_opens_the_dm_once(tmp_path, monkeypatch, notices):
    client = RecordingClient()
    steps = [_msg("m1", "slack-U0BFD9NDVE3", "one"), _msg("m2", "slack-U0BFD9NDVE3", "two")]
    _drive(tmp_path, monkeypatch, steps, client)
    assert client.opened == ["U0BFD9NDVE3"]
    assert [p["channel"] for p in client.posts] == ["D-U0BFD9NDVE3", "D-U0BFD9NDVE3"]
    assert [n["status"] for n in notices] == ["delivered", "delivered"]
    assert notices[0]["channel"] == "D-U0BFD9NDVE3"


def test_malformed_slack_address_fails_loudly(tmp_path, monkeypatch, notices, caplog):
    """The bug of 2026-09-05..09: a slack- name the grammar rejects was
    dropped with no trace. Now: no post, a failed notice, a journal warning."""
    client = RecordingClient()
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-...", "x"), _msg("m2", "slack-nick", "y")], client)
    assert client.posts == []
    assert [n["status"] for n in notices] == ["failed", "failed"]
    assert [n["trigger_step"] for n in notices] == ["m1", "m2"]
    assert "unknown slack address form" in notices[0]["reason"]
    assert "slack-C<id>" in notices[0]["reason"]
    assert notices[0]["content"].startswith("not delivered to slack-...")
    assert any("undeliverable address" in r.message for r in caplog.records)


def test_other_transports_get_no_notice(tmp_path, monkeypatch, notices):
    client = RecordingClient()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1"), _msg("m2", "pwa-andy")], client)
    assert client.posts == [] and notices == []


def test_slack_api_failure_is_a_failed_notice(tmp_path, monkeypatch, notices):
    client = RecordingClient(fail_post=True)
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-U1-C1-1.2")], client)
    assert notices[0]["status"] == "failed"
    assert "channel_not_found" in notices[0]["reason"]
    assert "ts" not in notices[0]


def test_duplicate_within_window_is_a_skipped_notice(tmp_path, monkeypatch, notices):
    client = RecordingClient()
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-C1", "same"), _msg("m2", "slack-C1", "same")], client)
    assert len(client.posts) == 1
    assert [n["status"] for n in notices] == ["delivered", "skipped"]
    assert "duplicate" in notices[1]["reason"]


def test_dm_open_failure_is_a_failed_notice(tmp_path, monkeypatch, notices):
    class NoDm(RecordingClient):
        def conversations_open(self, users):
            raise RuntimeError("user_not_found")
    client = NoDm()
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-U9")], client)
    assert client.posts == []
    assert notices[0]["status"] == "failed" and "user_not_found" in notices[0]["reason"]


def test_file_upload_writes_a_delivered_notice(tmp_path, monkeypatch, notices):
    body = b"hello file\n"
    step = {"type": "message", "from": "audel", "to": "slack-C1", "source": "chat",
            "filename": "note.txt", "content": "hello file",
            "content_b64": base64.b64encode(body).decode("ascii"), "step_id": "f1"}

    class Uploader(RecordingClient):
        def files_upload_v2(self, **kw):
            return {"ok": True}
    _drive(tmp_path, monkeypatch, [step], Uploader())
    assert notices[0]["status"] == "delivered" and notices[0]["filename"] == "note.txt"
    assert notices[0]["channel"] == "C1"


def test_client_without_ts_still_confirms(tmp_path, monkeypatch, notices):
    """Older fakes and clients return None; delivery is still recorded, just
    without ts or permalink."""
    class Bare:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            return None
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-U1-C1")], Bare())
    assert notices[0]["status"] == "delivered"
    assert "ts" not in notices[0] and "permalink" not in notices[0]


def test_append_step_via_traj_uses_bin_traj(tmp_path, monkeypatch):
    """The production writer shells out to bin/traj with the trajectory's dir
    and hex prefix, and feeds the step as JSON on stdin."""
    calls = []

    def fake_run(argv, **kw):
        calls.append((argv, kw))

        class R:
            returncode = 0
        return R()
    monkeypatch.setattr(outbound.subprocess, "run", fake_run)
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "traj").write_text("#!/bin/sh\n")
    traj_path = tmp_path / "trajectories" / "455a2181-root" / "trajectory.jsonl"
    outbound._append_step_via_traj(tmp_path, traj_path, {"type": "delivery", "status": "delivered"})
    argv, kw = calls[0]
    assert argv[0] == str(tmp_path / "bin" / "traj")
    assert argv[1:] == ["append", "--traj_dir", str(tmp_path / "trajectories"), "455a2181"]
    assert '"type": "delivery"' in kw["input"]
    assert kw["check"] is True
