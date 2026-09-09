"""Mind log -> Telegram.

Follows the identity's root trajectory and forwards message steps the
identity addressed to a telegram-* conversation name. The bridge's own
inbound steps have a telegram-* `from` (not the identity), so they never
match — no echo loop.

The allowlist gates this direction too: an injected agent that emits a
step addressed to an unapproved chat gets dropped here, so the bridge
can't be used as a courier out.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

import httpx

from . import mindlog, naming
from .filepayload import file_payload, file_signature
from .allowlist import Allowlist
from .api import ApiError, Bot
from .config import Config
from .tgfmt import chunk, strip_leaked_command, to_html

log = logging.getLogger(__name__)

DUPLICATE_WINDOW_SECONDS = 300
SOURCE = "telegram-bridge"
TRANSPORT = "telegram"


class RecentPosts:
    """Transport-level dedupe: agents occasionally send the same reply twice
    (e.g. an agentic run re-executing its chat command). Posting an identical
    message to the same conversation twice within the window is never right.
    """

    def __init__(self, window: float = DUPLICATE_WINDOW_SECONDS):
        self._window = window
        self._last: dict[str, tuple[str, float]] = {}

    def is_duplicate(self, conversation: str, text: str, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        previous = self._last.get(conversation)
        if previous and previous[0] == text and now - previous[1] < self._window:
            return True
        self._last[conversation] = (text, now)
        return False


# --- delivery notices -------------------------------------------------------
# Copied from headlong_slack.outbound (the bridges are independent uv
# projects) — keep the step shape in sync. See design/outbound_delivery.md.

def _append_step_via_traj(serve_root: Path, traj_path: Path, step: dict[str, Any]) -> None:
    """Append a step to the root trajectory through bin/traj, the same lock
    every other writer uses. The bridge never opens the file for writing."""
    traj_bin = serve_root / "bin" / "traj"
    if not traj_bin.is_file():
        found = shutil.which("traj")
        if not found:
            raise FileNotFoundError("bin/traj not found; cannot write delivery notice")
        traj_bin = Path(found)
    # bin/traj takes a mkdir lock beside the file, so the directory must be
    # writable too. Fail here, not by spinning: the Telegram bridge runs as
    # a user with read-only access to the trajectory, and its first notices
    # each hung for the full timeout (2026-09-09).
    if not (os.access(traj_path, os.W_OK) and os.access(traj_path.parent, os.W_OK)):
        raise PermissionError(f"{traj_path} is not writable by this user")
    subprocess.run(
        [str(traj_bin), "append", "--traj_dir", str(traj_path.parent.parent), traj_path.parent.name[:8]],
        input=json.dumps(step),
        text=True,
        check=True,
        capture_output=True,
        timeout=10,
    )


# Tests replace this with a collector; production writes through bin/traj.
append_step = _append_step_via_traj
# Set after the first PermissionError so a bridge that cannot write the log
# says so once and stops trying, instead of paying a timeout per send.
_notices_disabled = False


def _notice(cfg: Config, traj_path: Path, step: dict[str, Any], status: str, **fields: Any) -> None:
    """One `delivery` step per outbound message: delivered, failed (with the
    reason), or skipped. trigger_step names the message step. Never raises."""
    to = str(step.get("to") or "")
    if status == "delivered":
        content = f"delivered to {to}"
    elif status == "skipped":
        content = f"not sent to {to}: {fields.get('reason', 'skipped')}"
    else:
        content = f"not delivered to {to}: {fields.get('reason', 'unknown error')}"
    record: dict[str, Any] = {
        "type": "delivery", "source": SOURCE, "transport": TRANSPORT,
        "status": status, "to": to, "content": content,
    }
    if step.get("step_id"):
        record["trigger_step"] = step["step_id"]
    for key, value in fields.items():
        if value is not None and value != "":
            record[key] = value
    global _notices_disabled
    if _notices_disabled:
        return
    try:
        append_step(cfg.serve_root, traj_path, record)
    except PermissionError as exc:
        _notices_disabled = True
        log.error("delivery notices disabled for this run: %s", exc)
    except Exception:
        log.exception("could not write delivery notice for step %s", step.get("step_id"))


def _exc_reason(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"[:200]


def run(cfg: Config, bot: Bot, allowlist: Allowlist, stop_event: threading.Event) -> None:
    traj = mindlog.find_trajectory(cfg.identity_dir)
    cursor = cfg.state_dir / "cursor"
    recent = RecentPosts()
    log.info("following %s", traj)
    for step in mindlog.follow(traj, cursor, should_stop=stop_event.is_set):
        if step.get("type") != "message" or step.get("from") != cfg.identity:
            continue
        if step.get("source") != "chat":
            # Only bin/chat speaks for the identity — it stamps source:"chat"
            # on every outgoing message. Thinkers sometimes append raw message
            # steps directly to the trajectory (thinking out loud, not a
            # reply); delivering those gives the user a second, unstamped
            # voice. Bridges are the mouth; the trajectory is the mind.
            log.warning(
                "dropping non-chat message step %s (source=%r)",
                step.get("step_id"),
                step.get("source"),
            )
            continue
        to = step.get("to")
        if not isinstance(to, str) or not to.startswith(naming.PREFIX + "-"):
            continue  # another transport's message; its bridge owns it
        if not naming.is_telegram_name(to):
            log.warning("undeliverable address %r on step %s", to, step.get("step_id"))
            _notice(cfg, traj, step, "failed",
                    reason="unknown telegram address form; accepted: telegram-<user id>-<chat id>")
            continue
        conv = naming.decode(to)
        if "reaction" in step:
            # Slack-only: a chat-react step must not become a Telegram message.
            continue
        if not allowlist.is_approved(conv.user):
            log.warning("dropping reply to unapproved user %s", conv.user)
            _notice(cfg, traj, step, "failed", reason="recipient is not on the Telegram allowlist")
            continue
        if conv.user != conv.chat:
            log.warning("dropping reply to group chat %s", conv.chat)
            _notice(cfg, traj, step, "failed", reason="group chats are not supported; DMs only")
            continue
        payload = file_payload(step)
        if payload is not None:
            # File steps travel in content_b64 and often have empty `content`.
            # Do not require text, and do not fall back to posting bytes as a message.
            name = payload["filename"]
            data = payload["content"]
            caption = payload.get("caption")
            sent_file = False
            reason = ""
            if payload.get("decode_error") or data is None:
                reason = f"undecodable file payload ({name})"
                log.error("undecodable file payload for %s (%s)", to, name)
            elif recent.is_duplicate(to, file_signature(name, data)):
                log.warning("skipping duplicate file post to %s", to)
                _notice(cfg, traj, step, "skipped", reason="duplicate of a file sent within 5 minutes", filename=name)
                continue
            else:
                try:
                    if payload.get("as_photo") and hasattr(bot, "send_photo"):
                        try:
                            bot.send_photo(conv.chat, data, name, caption=caption)
                            sent_file = True
                        except ApiError:
                            if not hasattr(bot, "send_document"):
                                raise
                            bot.send_document(conv.chat, data, name, caption=caption)
                            sent_file = True
                    elif hasattr(bot, "send_document"):
                        bot.send_document(conv.chat, data, name, caption=caption)
                        sent_file = True
                    else:
                        reason = "bot cannot send files"
                        log.error("bot cannot send files for %s", to)
                except (ApiError, httpx.HTTPError) as exc:
                    reason = _exc_reason(exc)
                    log.exception("file send failed for %s", to)
            if sent_file:
                _notice(cfg, traj, step, "delivered", chat=str(conv.chat), filename=name)
            else:
                # Cursor already advanced past this step; tell the user
                # the upload was lost rather than failing silently.
                notice = f"(failed to deliver file {name})"
                try:
                    bot.send_message(conv.chat, notice)
                except (ApiError, httpx.HTTPError):
                    log.exception("delivery-failed notice also failed for %s", to)
                _notice(cfg, traj, step, "failed", reason=reason, filename=name)
            continue
        text = strip_leaked_command(str(step.get("content") or "")).strip()
        if not text:
            continue
        if recent.is_duplicate(to, text):
            log.warning("skipping duplicate post to %s", to)
            _notice(cfg, traj, step, "skipped", reason="duplicate of a message sent within 5 minutes")
            continue
        failure: str | None = None
        sent_parts = 0
        for part in chunk(text):
            try:
                bot.send_message(conv.chat, to_html(part), html=True)
                sent_parts += 1
            except ApiError:
                # Bad HTML from an odd reply must not eat the message —
                # fall back to plain text before giving up.
                try:
                    bot.send_message(conv.chat, part)
                    sent_parts += 1
                except (ApiError, httpx.HTTPError) as exc:
                    failure = _exc_reason(exc)
                    log.exception("sendMessage failed for %s", to)
                    break
            except httpx.HTTPError as exc:
                failure = _exc_reason(exc)
                log.exception("sendMessage failed for %s", to)
                break
        if failure is None:
            _notice(cfg, traj, step, "delivered", chat=str(conv.chat))
        elif sent_parts:
            _notice(cfg, traj, step, "failed", reason=f"partly sent, then {failure}", chat=str(conv.chat))
        else:
            _notice(cfg, traj, step, "failed", reason=failure)


def start(
    cfg: Config, bot: Bot, allowlist: Allowlist, stop_event: threading.Event
) -> threading.Thread:
    thread = threading.Thread(
        target=run,
        args=(cfg, bot, allowlist, stop_event),
        name="telegram-outbound",
        daemon=True,
    )
    thread.start()
    return thread
