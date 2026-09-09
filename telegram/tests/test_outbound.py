from headlong_telegram.outbound import RecentPosts


def test_recent_posts_dedupe_window():
    recent = RecentPosts(window=300)
    assert not recent.is_duplicate("telegram-1-1", "hi", now=0)
    assert recent.is_duplicate("telegram-1-1", "hi", now=100)
    assert not recent.is_duplicate("telegram-1-1", "hi", now=500)
    assert not recent.is_duplicate("telegram-2-2", "hi", now=100)


def test_run_delivers_only_chat_sourced_messages(tmp_path, monkeypatch):
    """Only bin/chat speaks for the identity: message steps without
    source:"chat" (a thinker appending raw message steps to the trajectory)
    must not reach Telegram."""
    import threading

    from headlong_telegram import outbound
    from headlong_telegram.config import Config

    steps = [
        # legit reply, stamped by bin/chat
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "real reply", "step_id": "aaa"},
        # forged: thinker-appended, wrong source
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "responder", "content": "forged reply", "step_id": "bbb"},
        # forged: no source at all
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "content": "unstamped reply", "step_id": "ccc"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", admin_id=1, web_url="http://x", state_dir=tmp_path,
    )
    outbound.run(cfg, FakeBot(), ApproveAll(), threading.Event())

    assert sent == ["real reply"]


import base64
import threading

from headlong_telegram.api import ApiError
from headlong_telegram import outbound
from headlong_telegram.config import Config


def _cfg(tmp_path):
    return Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", admin_id=1, web_url="http://x", state_dir=tmp_path,
    )


def test_forged_source_is_not_posted(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "real reply", "step_id": "aaa"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "responder", "content": "forged reply", "step_id": "bbb"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "content": "unstamped reply", "step_id": "ccc"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["real reply"]


def test_file_step_uses_send_document_not_message(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "ddd"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append((filename, content, caption))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == [("note.txt", "hi", None)]
    assert sent == []


def test_png_uses_send_photo(tmp_path, monkeypatch):
    png = b"\x89PNG\r\n\x1a\n" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat",
         "filename": "fig.png",
         "content_b64": base64.b64encode(png).decode("ascii"),
         "step_id": "fff"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    photos = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_photo(self, chat, content, filename, caption=None):
            photos.append((filename, content, caption))

        def send_document(self, chat, content, filename, caption=None):
            raise AssertionError("png should use send_photo")

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert photos == [("fig.png", png, None)]
    assert sent == []


def test_send_photo_retries_as_document(tmp_path, monkeypatch):
    png = b"\x89PNG\r\n\x1a\n" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat",
         "filename": "fig.png",
         "content_b64": base64.b64encode(png).decode("ascii"),
         "step_id": "ggg"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    photos = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            raise AssertionError("should not send_message")

        def send_photo(self, chat, content, filename, caption=None):
            photos.append(filename)
            raise ApiError("PHOTO_INVALID")

        def send_document(self, chat, content, filename, caption=None):
            docs.append((filename, content, caption))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert photos == ["fig.png"]
    assert docs == [("fig.png", png, None)]


def test_group_chat_is_dropped(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-99",
         "source": "chat", "content": "group hi", "step_id": "hhh"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == []

def test_jpeg_uses_send_photo(tmp_path, monkeypatch):
    jpeg = b"\xff\xd8\xff" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat",
         "filename": "shot.jpg",
         "content_b64": base64.b64encode(jpeg).decode("ascii"),
         "step_id": "jpg1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    photos = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_photo(self, chat, content, filename, caption=None):
            photos.append((filename, content, caption))

        def send_document(self, chat, content, filename, caption=None):
            raise AssertionError("jpeg should use send_photo")

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert photos == [("shot.jpg", jpeg, None)]
    assert sent == []


def test_file_send_failure_falls_back_to_notice(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound
    from headlong_telegram.api import ApiError

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "fail1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            raise ApiError("upload rejected")

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["(failed to deliver file note.txt)"]


def test_undecodable_file_falls_back_to_notice(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt",
         "content": "[file: note.txt]", "content_b64": "@@@bad@@@",
         "step_id": "badb64"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append(filename)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == []
    assert sent == ["(failed to deliver file note.txt)"]


def test_identical_file_steps_are_suppressed(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound

    body = b"same-bytes"
    b64 = base64.b64encode(body).decode("ascii")
    other = b"different-bytes"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "f1"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "f2"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt",
         "content_b64": base64.b64encode(other).decode("ascii"),
         "step_id": "f3"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append((filename, content, caption))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == [("note.txt", body, None), ("note.txt", other, None)]
    assert sent == []


def test_invalid_file_content_does_not_stop_later_replies(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "bad.bin",
         "content": {"x": "y"}, "step_id": "badobj"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "later reply", "step_id": "okmsg"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append(filename)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == []
    assert sent == ["(failed to deliver file bad.bin)", "later reply"]



def test_slack_reaction_step_is_not_posted(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "reaction": "thumbsup", "content": ":thumbsup:",
         "step_id": "r1"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "later reply", "step_id": "t1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["later reply"]


# --- delivery notices (design/outbound_delivery.md, part 7) -------------------

def _drive(tmp_path, monkeypatch, steps, bot, approve=True):
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    class Allow:
        def is_approved(self, user):
            return approve
    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", admin_id=1, web_url="http://x", state_dir=tmp_path,
    )
    outbound.run(cfg, bot, Allow(), threading.Event())


def _msg(step_id, to, content="hello"):
    return {"type": "message", "from": "audel", "to": to, "source": "chat",
            "content": content, "step_id": step_id}


class Bot:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    def send_message(self, chat, text, html=False):
        if self.fail:
            raise ApiError("chat not found")
        self.sent.append(text)


def test_delivered_notice_names_the_message_step(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "hi")], bot)
    assert bot.sent == ["hi"]
    n = notices[0]
    assert n["type"] == "delivery" and n["source"] == "telegram-bridge" and n["transport"] == "telegram"
    assert n["status"] == "delivered" and n["trigger_step"] == "m1" and n["chat"] == "1"
    assert n["content"] == "delivered to telegram-1-1"


def test_send_failure_is_a_failed_notice(tmp_path, monkeypatch, notices):
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1")], Bot(fail=True))
    assert notices[0]["status"] == "failed" and "chat not found" in notices[0]["reason"]


def test_unapproved_and_group_and_malformed_are_failed_notices(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1")], bot, approve=False)
    _drive(tmp_path, monkeypatch, [_msg("m2", "telegram-1-2"), _msg("m3", "telegram-bogus")], bot)
    assert bot.sent == []
    assert [n["trigger_step"] for n in notices] == ["m1", "m2", "m3"]
    assert "allowlist" in notices[0]["reason"]
    assert "group" in notices[1]["reason"]
    assert "unknown telegram address form" in notices[2]["reason"]


def test_other_transports_get_no_notice(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-U1-C1"), _msg("m2", "pwa-andy")], bot)
    assert bot.sent == [] and notices == []


def test_duplicate_is_a_skipped_notice(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "x"), _msg("m2", "telegram-1-1", "x")], bot)
    assert bot.sent == ["x"]
    assert [n["status"] for n in notices] == ["delivered", "skipped"]


def test_unwritable_trajectory_disables_notices_after_one_error(tmp_path, monkeypatch, notices, caplog):
    calls = []

    def denied(serve_root, traj_path, step):
        calls.append(step)
        raise PermissionError("not writable")
    monkeypatch.setattr(outbound, "append_step", denied)
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "a"), _msg("m2", "telegram-1-1", "b")], bot)
    assert bot.sent == ["a", "b"]
    assert len(calls) == 1
    assert sum("delivery notices disabled" in r.message for r in caplog.records) == 1
