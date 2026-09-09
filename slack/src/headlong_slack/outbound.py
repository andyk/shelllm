"""Mind log -> Slack.

Follows the identity's root trajectory and forwards message steps the
identity addressed to a slack-* conversation name. The bridge's own
inbound steps have a slack-* `from` (not the identity), so they never
match — no echo loop.

Every send gets a `delivery` step written back to the trajectory, either
delivered (with the Slack ts and permalink) or failed (with the reason), so
the mind can tell "I spoke" from "I tried to". Before this, a malformed
address was dropped with no trace and the mind re-sent the same papers four
times believing none had gone out (design/outbound_delivery.md).
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from . import mindlog, naming
from .config import Config
from .filepayload import file_payload, file_signature
from .slackfmt import chunk, strip_leaked_command, to_mrkdwn
from .state import ActiveThreads

log = logging.getLogger(__name__)

DUPLICATE_WINDOW_SECONDS = 300
SOURCE = "slack-bridge"
TRANSPORT = "slack"


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
        if self.seen(conversation, text, now=now):
            return True
        self.record(conversation, text, now=now)
        return False

    def seen(self, conversation: str, text: str, now: float | None = None) -> bool:
        """True if this payload was already recorded in the window. Does not record."""
        now = time.time() if now is None else now
        previous = self._last.get(conversation)
        return bool(previous and previous[0] == text and now - previous[1] < self._window)

    def record(self, conversation: str, text: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        self._last[conversation] = (text, now)


def reaction_name(step: dict[str, Any]) -> str | None:
    """Slack emoji name from a chat-react step, or None if this is not one."""
    raw = step.get("reaction")
    if not isinstance(raw, str):
        return None
    name = raw.strip().strip(":")
    if not name or any(c.isspace() for c in name):
        return None
    if not all(c.isalnum() or c in "_+-:" for c in name):
        return None
    if len(name) > 100:
        return None
    return name


def message_ts_from_source_url(url: object) -> str | None:
    """Decode Slack archive permalink /archives/<channel>/p<ts-without-dot>."""
    if not isinstance(url, str) or not url:
        return None
    try:
        parts = [p for p in urlsplit(url).path.split("/") if p]
    except ValueError:
        return None
    if len(parts) < 3 or parts[-3] != "archives":
        return None
    last = parts[-1]
    if not last.startswith("p") or not last[1:].isdigit() or len(last) < 8:
        return None
    digits = last[1:]
    return f"{digits[:-6]}.{digits[-6:]}"


def _already_reacted(exc: BaseException) -> bool:
    resp = getattr(exc, "response", None)
    error = ""
    if isinstance(resp, dict):
        error = str(resp.get("error") or "")
    elif resp is not None and hasattr(resp, "get"):
        error = str(resp.get("error") or "")
    return error == "already_reacted" or "already_reacted" in str(exc)


def _add_reaction(
    client: Any,
    conv: naming.Conversation,
    name: str,
    timestamp: str,
) -> None:
    try:
        client.reactions_add(channel=conv.channel, timestamp=timestamp, name=name)
    except Exception as exc:
        if _already_reacted(exc):
            return
        raise


def _post_notice(client: Any, conv: naming.Conversation, text: str) -> None:
    try:
        client.chat_postMessage(
            channel=conv.channel,
            thread_ts=conv.thread_ts,
            text=text,
            unfurl_links=False,
        )
    except Exception:
        log.exception("delivery-failed notice also failed for %s/%s", conv.channel, conv.thread_ts)


def _upload_file(
    client: Any,
    conv: naming.Conversation,
    filename: str,
    data: bytes | str,
    comment: str | None,
) -> Any:
    kwargs: dict[str, Any] = {
        "channel": conv.channel,
        "filename": filename,
        "title": filename,
        "content": data,
    }
    if conv.thread_ts:
        kwargs["thread_ts"] = conv.thread_ts
    if comment:
        kwargs["initial_comment"] = comment
    return client.files_upload_v2(**kwargs)


def _resp_get(resp: Any, key: str) -> Any:
    """Field from a slack_sdk response, a plain dict, or nothing (fake clients)."""
    if resp is None:
        return None
    if isinstance(resp, dict):
        return resp.get(key)
    getter = getattr(resp, "get", None)
    if callable(getter):
        try:
            return getter(key)
        except Exception:
            return None
    data = getattr(resp, "data", None)
    if isinstance(data, dict):
        return data.get(key)
    return None


def _exc_reason(exc: BaseException) -> str:
    resp = getattr(exc, "response", None)
    err = _resp_get(resp, "error")
    text = f"{type(exc).__name__}: {err or exc}"
    return text[:200]


# --- delivery notices -------------------------------------------------------

def _append_step_via_traj(serve_root: Path, traj_path: Path, step: dict[str, Any]) -> None:
    """Append a step to the root trajectory through bin/traj, the same lock
    every other writer uses. The bridge never opens the file for writing.

    traj resolves an ID that is a UUID or a hex prefix; the trajectory's
    directory is named <hex8>-<slug>, so its first 8 characters are enough.
    """
    traj_bin = serve_root / "bin" / "traj"
    if not traj_bin.is_file():
        found = shutil.which("traj")
        if not found:
            raise FileNotFoundError("bin/traj not found; cannot write delivery notice")
        traj_bin = Path(found)
    traj_dir = traj_path.parent.parent
    traj_id = traj_path.parent.name[:8]
    subprocess.run(
        [str(traj_bin), "append", "--traj_dir", str(traj_dir), traj_id],
        input=json.dumps(step),
        text=True,
        check=True,
        capture_output=True,
        timeout=30,
    )


# Tests replace this with a collector; production writes through bin/traj.
append_step = _append_step_via_traj


def _notice(
    cfg: Config,
    traj_path: Path,
    step: dict[str, Any],
    status: str,
    **fields: Any,
) -> None:
    """Write one delivery step for an outbound message step.

    status is delivered, failed, or skipped. trigger_step names the message
    step the notice is about, so a later reader (chat sent, the wake prompt)
    can resolve a send by matching it. Never raises: a notice that cannot be
    written must not stop delivery of the next message.
    """
    to = str(step.get("to") or "")
    if status == "delivered":
        content = f"delivered to {to}"
    elif status == "skipped":
        content = f"not sent to {to}: {fields.get('reason', 'skipped')}"
    else:
        content = f"not delivered to {to}: {fields.get('reason', 'unknown error')}"
    record: dict[str, Any] = {
        "type": "delivery",
        "source": SOURCE,
        "transport": TRANSPORT,
        "status": status,
        "to": to,
        "content": content,
    }
    if step.get("step_id"):
        record["trigger_step"] = step["step_id"]
    for key, value in fields.items():
        if value is not None and value != "":
            record[key] = value
    try:
        append_step(cfg.serve_root, traj_path, record)
    except Exception:
        log.exception("could not write delivery notice for step %s", step.get("step_id"))


def _permalink(client: Any, channel: str, ts: str | None) -> str | None:
    if not ts or not hasattr(client, "chat_getPermalink"):
        return None
    try:
        resp = client.chat_getPermalink(channel=channel, message_ts=ts)
    except Exception:
        return None
    link = _resp_get(resp, "permalink")
    return str(link) if link else None


class DmChannels:
    """Resolve a bare user id to its DM channel with conversations.open, once."""

    def __init__(self) -> None:
        self._cache: dict[str, str] = {}

    def resolve(self, client: Any, user: str) -> str:
        if user in self._cache:
            return self._cache[user]
        if not hasattr(client, "conversations_open"):
            raise RuntimeError("client cannot open DMs (conversations_open missing)")
        resp = client.conversations_open(users=user)
        channel = _resp_get(resp, "channel")
        channel_id = _resp_get(channel, "id") if channel is not None else None
        if not channel_id:
            raise RuntimeError(f"conversations.open returned no channel for {user}")
        self._cache[user] = str(channel_id)
        return self._cache[user]


def run(
    cfg: Config,
    client: Any,
    threads: ActiveThreads,
    stop_event: threading.Event,
) -> None:
    traj = mindlog.find_trajectory(cfg.identity_dir)
    cursor = cfg.state_dir / "cursor"
    recent = RecentPosts()
    dms = DmChannels()
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
        if not naming.looks_like_slack(to):
            continue  # another transport's message; its bridge owns it
        if not naming.is_slack_name(to):
            reason = f"unknown slack address form; accepted: {naming.ACCEPTED_FORMS}"
            log.warning("undeliverable address %r on step %s", to, step.get("step_id"))
            _notice(cfg, traj, step, "failed", reason=reason)
            continue
        conv = naming.decode(to)
        if "reaction" in step:
            name = reaction_name(step)
            ts = message_ts_from_source_url(step.get("source_url")) or conv.thread_ts
            sig = f"react:{name}:{ts}" if name and ts else None
            if not name:
                log.error("invalid reaction on step %s", step.get("step_id"))
            elif not ts:
                log.error("reaction %s for %s has no message timestamp", name, to)
            elif not conv.channel:
                log.error("reaction %s for %s needs a channel", name, to)
            elif sig is not None and recent.seen(to, sig):
                log.warning("skipping duplicate reaction %s on %s", name, to)
            elif not hasattr(client, "reactions_add"):
                log.error("client cannot add reactions for %s", to)
            else:
                try:
                    _add_reaction(client, conv, name, ts)
                    recent.record(to, sig)
                except Exception:
                    log.exception("reactions.add failed for %s (%s)", to, name)
            continue
        # A bare user id means "DM this person": open (or look up) the DM
        # channel first, so the rest of the path only ever sees a channel.
        if not conv.channel:
            try:
                conv = conv._replace(channel=dms.resolve(client, conv.user))
            except Exception as exc:
                log.exception("could not open DM with %s for %s", conv.user, to)
                _notice(cfg, traj, step, "failed", reason=_exc_reason(exc))
                continue
        payload = file_payload(step)
        if payload is not None:
            # File steps travel in content_b64 and often have empty `content`.
            # Do not require text, and do not fall back to posting bytes as a message.
            name = payload["filename"]
            data = payload["content"]
            comment = payload.get("initial_comment")
            sent_file = False
            reason = ""
            resp = None
            sig = file_signature(name, data) if data is not None else None
            if payload.get("decode_error") or data is None:
                reason = f"undecodable file payload ({name})"
                log.error("undecodable file payload for %s (%s)", to, name)
            elif sig is not None and recent.seen(to, sig):
                log.warning("skipping duplicate file post to %s", to)
                _notice(cfg, traj, step, "skipped", reason="duplicate of a file posted within 5 minutes", filename=name)
                continue
            elif not hasattr(client, "files_upload_v2"):
                reason = "client cannot upload files"
                log.error("client cannot upload files for %s", to)
            else:
                try:
                    resp = _upload_file(client, conv, name, data, comment)
                    sent_file = True
                    if sig is not None:
                        recent.record(to, sig)
                except Exception as exc:
                    reason = _exc_reason(exc)
                    log.exception("file upload failed for %s", to)
            threads.touch(conv.channel, conv.thread_ts)
            if sent_file:
                _notice(cfg, traj, step, "delivered", channel=conv.channel, filename=name)
            else:
                _post_notice(client, conv, f"(failed to deliver file {name})")
                _notice(cfg, traj, step, "failed", reason=reason, filename=name)
            continue
        text = to_mrkdwn(strip_leaked_command(str(step.get("content") or ""))).strip()
        if not text:
            continue
        if recent.is_duplicate(to, text):
            log.warning("skipping duplicate post to %s", to)
            _notice(cfg, traj, step, "skipped", reason="duplicate of a post within 5 minutes")
            continue
        threads.touch(conv.channel, conv.thread_ts)
        first_ts: str | None = None
        failure: str | None = None
        for part in chunk(text):
            try:
                resp = client.chat_postMessage(
                    channel=conv.channel,
                    thread_ts=conv.thread_ts,
                    text=part,
                    unfurl_links=False,
                )
            except Exception as exc:
                failure = _exc_reason(exc)
                log.exception("chat_postMessage failed for %s", to)
                break
            if first_ts is None:
                ts = _resp_get(resp, "ts")
                first_ts = str(ts) if ts else None
        if failure is not None and first_ts is None:
            _notice(cfg, traj, step, "failed", reason=failure)
        elif failure is not None:
            _notice(
                cfg, traj, step, "failed",
                reason=f"partly posted, then {failure}",
                channel=conv.channel, ts=first_ts,
                permalink=_permalink(client, conv.channel, first_ts),
            )
        else:
            _notice(
                cfg, traj, step, "delivered",
                channel=conv.channel, ts=first_ts,
                permalink=_permalink(client, conv.channel, first_ts),
            )


def start(
    cfg: Config,
    client: Any,
    threads: ActiveThreads,
    stop_event: threading.Event,
) -> threading.Thread:
    thread = threading.Thread(
        target=run,
        args=(cfg, client, threads, stop_event),
        name="slack-outbound",
        daemon=True,
    )
    thread.start()
    return thread
