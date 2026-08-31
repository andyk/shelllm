"""FastAPI app factory for the Headlong dash (web viewer)."""

import json
import logging
import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.background import BackgroundTask

from headlong_web import (
    activity,
    chat,
    control,
    discovery,
    env,
    envfile,
    liveness,
    llm_health,
    logs,
    memories,
    openrouter,
    push,
    safety,
    search,
    thinker_sync,
    thinkers,
    trajectory,
    tree,
    usage,
)

# Direct import: the bare module name would be shadowed inside create_app
# by the GET /api/health route function.
from headlong_web.health import response_stats

logger = logging.getLogger(__name__)

VERSION = "0.1.0"

# The repo the running server code lives in (…/web/src/headlong_web/server.py)
_CODE_REPO = Path(__file__).resolve().parents[3]

# The built frontend; deleting it makes the next startup rebuild (see cli.py).
_STATIC_DIR = Path(__file__).resolve().parent / "static"


def _schedule_restart(delay: float = 0.75) -> None:
    """Exit shortly after the current response flushes. Under systemd
    (Restart=always) the service comes back on the freshly pulled code and
    rebuilds static/; without a supervisor the process just stops."""
    threading.Timer(delay, lambda: os.kill(os.getpid(), signal.SIGTERM)).start()


def _git_info() -> dict[str, str | None]:
    """commit/branch of the code repo, or Nones outside a git checkout."""

    def rev_parse(*args: str) -> str | None:
        try:
            proc = subprocess.run(
                ["git", "-C", str(_CODE_REPO), "rev-parse", *args],
                capture_output=True, text=True, timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return proc.stdout.strip() or None if proc.returncode == 0 else None

    return {
        "git_commit": rev_parse("--short", "HEAD"),
        "git_branch": rev_parse("--abbrev-ref", "HEAD"),
    }


def _identity_or_404(root: Path, identity_id: str) -> discovery.IdentityInfo:
    try:
        return discovery.resolve_identity(root, identity_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Identity not found") from None


def _count_steps(jsonl: Path) -> int:
    try:
        with jsonl.open("rb") as fh:
            return sum(1 for line in fh if line.strip())
    except OSError:
        return 0


def _chatrc_default_from(root: Path) -> str | None:
    """The CLI's `default_send_from`, so the web UI can share its default
    sender. Mirrors bin/chat: `$CHATRC` (default `./.chatrc`) relative to the
    directory CLI calls run in, which is the serve root."""
    chatrc = Path(os.environ["CHATRC"]) if os.environ.get("CHATRC") else root / ".chatrc"
    try:
        for line in chatrc.read_text().splitlines():
            if line.startswith("default_send_from="):
                value = line.split("=", 1)[1].strip()
                return value or None
    except OSError:
        pass
    return None


def _iso(ts: float | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


class ThinkerActionBody(BaseModel):
    names: list[str] = []
    no_self_trigger: bool = False
    force: bool = False  # stop only: kill in-flight steps instead of draining


class ThinkerSyncBody(BaseModel):
    names: list[str] = []


class ChatSendBody(BaseModel):
    content: str
    from_name: str
    source_url: str | None = None


class PushSubscribeBody(BaseModel):
    name: str
    subscription: dict


class PushUnsubscribeBody(BaseModel):
    endpoint: str


class NewIdentityBody(BaseModel):
    name: str


class RecapRefreshBody(BaseModel):
    rebuild: bool = False


class UsageRefreshBody(BaseModel):
    rebuild: bool = False


class KillallBody(BaseModel):
    dry_run: bool = False


class EnvVarBody(BaseModel):
    key: str
    value: str


def create_app(
    root: Path, static_dir: Path | None = None, *, read_only: bool = False
) -> FastAPI:
    root = root.resolve()
    app = FastAPI(title="Headlong dash", version=VERSION)
    # Default "*" suits local use; deployments should pin this to their
    # public origin(s) via HEADLONG_WEB_ALLOWED_ORIGINS (comma-separated).
    allowed_origins = [
        origin.strip()
        for origin in env.getenv("HEADLONG_WEB_ALLOWED_ORIGINS", "*").split(",")
        if origin.strip()
    ]
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allowed_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    def _require_controls() -> None:
        if read_only:
            raise HTTPException(status_code=403, detail="Server is read-only")

    def _checked_thinker_names(identity: discovery.IdentityInfo, names: list[str]) -> None:
        enabled = {d.name for d in thinkers.list_thinker_dirs(identity.path)}
        installed = {
            d.name for d in thinkers.list_thinker_dirs(identity.path, include_disabled=True)
        }
        for name in names:
            if not safety.THINKER_NAME_RE.match(name):
                raise HTTPException(status_code=422, detail=f"Invalid thinker name: {name}")
            if name not in installed:
                raise HTTPException(status_code=404, detail=f"Thinker not found: {name}")
            if name not in enabled:
                raise HTTPException(
                    status_code=409,
                    detail=f"Thinker '{name}' is disabled — enable it first",
                )

    @app.get("/api/health")
    def health() -> dict:
        return {"status": "ok"}

    # Resolved once at startup: the code can't change under a running server
    # (both update paths restart the service after pulling).
    git_info = _git_info()

    # Opt-in: the dash can pull its own repo and restart itself. Enabled on
    # the demo deployment (systemd restarts it); off by default elsewhere —
    # without a supervisor the process would just exit.
    self_update_enabled = (
        env.getenv("HEADLONG_WEB_SELF_UPDATE") == "1" and not read_only
    )
    update_lock = threading.Lock()

    @app.get("/api/config")
    def config() -> dict:
        return {
            "root": str(root),
            "version": VERSION,
            "controls_enabled": not read_only,
            "self_update_enabled": self_update_enabled,
            "default_send_from": _chatrc_default_from(root),
            **git_info,
        }

    @app.post("/api/update", status_code=202)
    def self_update() -> dict:
        _require_controls()
        if not self_update_enabled:
            raise HTTPException(
                status_code=403,
                detail="Self-update is disabled (set HEADLONG_WEB_SELF_UPDATE=1)",
            )
        if not update_lock.acquire(blocking=False):
            raise HTTPException(status_code=409, detail="Update already in progress")
        # On success the lock is held until the process exits — by design.
        keep_locked = False
        try:
            try:
                proc = subprocess.run(
                    ["git", "-C", str(_CODE_REPO), "pull", "--ff-only"],
                    capture_output=True, text=True, timeout=180,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise HTTPException(
                    status_code=500, detail=f"git pull failed: {exc}"
                ) from exc
            if proc.returncode != 0:
                stderr_lines = [l for l in (proc.stderr or "").splitlines() if l.strip()]
                raise HTTPException(
                    status_code=409,
                    detail={
                        "message": stderr_lines[-1] if stderr_lines else "git pull failed",
                        "stderr": proc.stderr,
                    },
                )
            new_commit = _git_info()["git_commit"]
            if new_commit == git_info["git_commit"]:
                return {
                    "ok": True,
                    "updated": False,
                    "commit": new_commit,
                    "restarting": False,
                }
            shutil.rmtree(_STATIC_DIR, ignore_errors=True)
            _schedule_restart()
            keep_locked = True
            return {
                "ok": True,
                "updated": True,
                "from_commit": git_info["git_commit"],
                "to_commit": new_commit,
                "restarting": True,
            }
        finally:
            if not keep_locked:
                update_lock.release()

    @app.get("/api/identities")
    def identities() -> list[dict]:
        result = []
        for identity in discovery.scan_identities(root):
            traj_dir = discovery.find_root_traj_dir(identity)
            jsonl = traj_dir / "trajectory.jsonl" if traj_dir else None
            status = liveness.identity_status(identity.path, jsonl)
            summary = thinkers.thinkers_summary(identity.path)
            result.append(
                {
                    "id": identity.id,
                    "name": identity.name,
                    "path_rel": identity.path_rel,
                    "created": identity.created,
                    "root_trajectory": identity.root_trajectory,
                    "group": identity.group,
                    "live": status["live"],
                    "last_activity_ts": _iso(status["mindlog_mtime"]),
                    "step_count": _count_steps(jsonl) if jsonl else 0,
                    **summary,
                }
            )
        result.sort(key=lambda item: item["last_activity_ts"] or "", reverse=True)
        return result

    @app.get("/api/identities/{identity_id}/status")
    def identity_status(identity_id: str) -> dict:
        identity = _identity_or_404(root, identity_id)
        traj_dir = discovery.find_root_traj_dir(identity)
        jsonl = traj_dir / "trajectory.jsonl" if traj_dir else None
        status = liveness.identity_status(identity.path, jsonl)
        status["step_count"] = _count_steps(jsonl) if jsonl else 0
        status["mindlog_mtime"] = _iso(status["mindlog_mtime"])
        return status

    @app.get("/api/identities/{identity_id}/activity")
    def identity_activity(identity_id: str) -> dict:
        """Working-vs-stalled classification: is the identity actually
        making progress, or busy-but-quiet? See activity.py."""
        identity = _identity_or_404(root, identity_id)
        return activity.identity_activity(identity)

    @app.get("/api/identities/{identity_id}/health")
    def identity_health(identity_id: str) -> dict:
        """Health page payload: current activity + reply_to-paired message
        response stats over the recent window. See health.py."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = discovery.find_root_traj_dir(identity)
        return {
            "identity": {"id": identity.id, "name": identity.name},
            "activity": activity.identity_activity(identity),
            "responses": (
                response_stats(traj_dir, identity.name)
                if traj_dir is not None
                else None
            ),
        }

    @app.get("/api/identities/{identity_id}/mindlog")
    def mindlog(
        identity_id: str,
        since: int | None = Query(default=None, ge=0),
        until: int | None = Query(default=None, ge=0),
        tail: int | None = Query(default=None, ge=1),
    ) -> dict:
        """Mind log steps, windowed. ?tail=N returns only the last N steps
        (the response's `since` echoes the effective start index — a
        20k-step log ships whole otherwise, hundreds of MB). ?since=A polls
        for steps after A; ?since=A&until=B loads the older [A, B) window.
        Runs ship filtered to those touched at/after the window start.
        Backed by the append-aware parse cache, so a poll costs O(new
        steps), not O(log)."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = discovery.find_root_traj_dir(identity)
        if traj_dir is None:
            raise HTTPException(status_code=404, detail="No mind log trajectory found")
        # The client always windows (?tail on load, ?since polls, bounded
        # backfills), so the hydrate cap never bites in practice — it only
        # keeps a pathological whole-log fetch from re-materializing GBs.
        cached = trajectory.CACHE.window(
            traj_dir, since=since, until=until, tail=tail,
            max_hydrate=128 * 1024 * 1024,
        )
        jsonl = traj_dir / "trajectory.jsonl"
        status = liveness.identity_status(identity.path, jsonl)
        runs = cached["runs"]
        since = cached["since"]
        if since is not None:
            # Only runs touched by a step at/after the window start — the
            # rest are unchanged and heavy (command embeds the whole prompt)
            runs = [run for run in runs if run["last_touch"] >= since]
        return {
            "steps": cached["steps"],
            "runs": runs,
            "traj_id": cached["traj_id"],
            "step_count": cached["step_count"],
            "since": since,
            "live": status["live"],
            "dir_rel": traj_dir.relative_to(identity.path).as_posix(),
            "identity": {"id": identity.id, "name": identity.name},
        }

    @app.get("/api/identities/{identity_id}/mindlog/search")
    def mindlog_search(
        identity_id: str,
        q: str = Query(min_length=2, max_length=200),
        scope: str = Query(default="thoughts", pattern="^(thoughts|all)$"),
        limit: int = Query(default=50, ge=1, le=200),
    ) -> dict:
        """Substring search over the mind log (read-only). scope=thoughts
        skips run machinery (prompts, reasoning, shell output); scope=all
        searches everything. See search.py."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        result = search.search_cache(trajectory.CACHE, traj_dir, q, scope, limit)
        result["step_count"] = trajectory.CACHE.load(traj_dir)["step_count"]
        result["identity"] = {"id": identity.id, "name": identity.name}
        return result

    @app.get("/api/identities/{identity_id}/step/{step_id}")
    def mindlog_step(identity_id: str, step_id: str) -> dict:
        """One normalized step by id, plus its run header — how a search
        hit older than the client's loaded window gets displayed."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        cached = trajectory.CACHE.load(traj_dir)
        steps = cached["steps"]
        for index in range(len(steps) - 1, -1, -1):
            if steps[index].get("step_id") == step_id:
                # hydrate: a hit this old has usually had its raw evicted
                step = trajectory.CACHE.window(traj_dir, index, index + 1)["steps"][0]
                run = next(
                    (r for r in cached["runs"] if r["run_id"] == step.get("run_id")),
                    None,
                )
                return {"step": step, "index": index, "run": run}
        raise HTTPException(status_code=404, detail="Step not found")

    @app.get("/api/identities/{identity_id}/runs/{run_id}/command")
    def run_command(identity_id: str, run_id: str) -> dict:
        """Full (untruncated) command of one run — fetched on demand when
        the run detail is opened; the mindlog payload truncates it."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        command = trajectory.CACHE.run_command(traj_dir, run_id)
        if command is None:
            raise HTTPException(status_code=404, detail="Run not found")
        return {"run_id": run_id, "command": command}

    def _root_traj_dir_or_404(identity: discovery.IdentityInfo):
        traj_dir = discovery.find_root_traj_dir(identity)
        if traj_dir is None:
            raise HTTPException(status_code=404, detail="No mind log trajectory found")
        return traj_dir

    @app.get("/api/identities/{identity_id}/tree")
    def identity_tree(
        identity_id: str,
        node: str | None = Query(default=None),
        depth: int = Query(default=2, ge=0, le=6),
    ) -> dict:
        identity = _identity_or_404(root, identity_id)
        root_traj_dir = _root_traj_dir_or_404(identity)
        target = root_traj_dir
        if node:
            found = tree.find_traj_dir(root_traj_dir, node)
            if found is None:
                raise HTTPException(status_code=404, detail="Trajectory not found")
            target = found
        return tree.build_tree(target, depth)

    @app.get("/api/identities/{identity_id}/traj/{traj_id}")
    def sub_trajectory(identity_id: str, traj_id: str) -> dict:
        identity = _identity_or_404(root, identity_id)
        root_traj_dir = _root_traj_dir_or_404(identity)
        traj_dir = tree.find_traj_dir(root_traj_dir, traj_id)
        if traj_dir is None:
            raise HTTPException(status_code=404, detail="Trajectory not found")
        # This endpoint ships the trajectory WHOLE (no windowing in the
        # client yet) — cap rehydration so a huge sub-trajectory serves its
        # newest ~32MB of raws and previews beyond that, instead of
        # re-materializing GBs. window() returns a fresh envelope dict.
        result = trajectory.CACHE.window(traj_dir, max_hydrate=32 * 1024 * 1024)
        result["breadcrumb"] = tree.breadcrumb(root_traj_dir, traj_dir)
        first_steps = trajectory.CACHE.window(traj_dir, 0, 1)["steps"]
        first = (first_steps[0].get("raw") or {}) if first_steps else {}
        parent_traj = first.get("parent_traj")
        result["parent"] = (
            {"traj_id": parent_traj, "step_id": first.get("parent_step")}
            if parent_traj
            else None
        )
        result["identity"] = {"id": identity.id, "name": identity.name}
        result["dir_rel"] = traj_dir.relative_to(identity.path).as_posix()
        status = liveness.identity_status(identity.path, traj_dir / "trajectory.jsonl")
        result["live"] = status["live"]
        return result

    @app.get("/api/identities/{identity_id}/traj/{traj_id}/blob/{name}")
    def blob(
        identity_id: str,
        traj_id: str,
        name: str,
        head: int = Query(default=262144, ge=1, le=8 * 1024 * 1024),
    ) -> Response:
        identity = _identity_or_404(root, identity_id)
        root_traj_dir = _root_traj_dir_or_404(identity)
        traj_dir = tree.find_traj_dir(root_traj_dir, traj_id)
        if traj_dir is None:
            raise HTTPException(status_code=404, detail="Trajectory not found")
        safety.checked_name(name, safety.BLOB_NAME_RE)
        blob_path = safety.contained_path(traj_dir / "blobs", name)
        if not blob_path.is_file():
            raise HTTPException(status_code=404, detail="Blob not found")
        total = blob_path.stat().st_size
        with blob_path.open("rb") as fh:
            data = fh.read(head)
        return Response(
            content=data,
            media_type="text/plain; charset=utf-8",
            headers={
                "X-Blob-Bytes": str(total),
                "X-Blob-Truncated": "1" if total > head else "0",
            },
        )

    @app.get("/api/identities/{identity_id}/logs")
    def identity_logs(identity_id: str) -> list[dict]:
        identity = _identity_or_404(root, identity_id)
        return logs.list_logs(identity.path)

    @app.get("/api/identities/{identity_id}/logs/{name}")
    def identity_log(
        identity_id: str,
        name: str,
        tail_bytes: int = Query(default=65536, ge=1, le=8 * 1024 * 1024),
    ) -> dict:
        identity = _identity_or_404(root, identity_id)
        safety.checked_name(name, safety.LOG_NAME_RE)
        log_path = safety.contained_path(identity.path / "run" / "logs", name)
        if not log_path.is_file():
            raise HTTPException(status_code=404, detail="Log not found")
        return logs.tail_log(log_path, tail_bytes)

    @app.get("/api/identities/{identity_id}/dispatch")
    def identity_dispatch(identity_id: str) -> list[dict]:
        identity = _identity_or_404(root, identity_id)
        return logs.parse_dispatch_log(identity.path)

    @app.get("/api/identities/{identity_id}/memories")
    def identity_memories(identity_id: str) -> list[dict]:
        identity = _identity_or_404(root, identity_id)
        return memories.list_memories(identity.path)

    @app.get("/api/identities/{identity_id}/memories/{name}")
    def identity_memory(identity_id: str, name: str) -> dict:
        identity = _identity_or_404(root, identity_id)
        safety.checked_name(name, safety.MEMORY_NAME_RE)
        memory_path = safety.contained_path(identity.path / "memories", name)
        if not memory_path.is_file():
            raise HTTPException(status_code=404, detail="Memory not found")
        return {"name": name, "content": memory_path.read_text(encoding="utf-8", errors="replace")}

    @app.get("/api/identities/{identity_id}/recap")
    def identity_recap(identity_id: str) -> dict:
        """Serve the cached recap (bin/recap output) for the mind log."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        cache = traj_dir / "recap"
        refreshing = (cache / ".lock").is_dir()
        base = {
            "identity": {"id": identity.id, "name": identity.name},
            "refreshing": refreshing,
        }
        themes_file = cache / "themes.json"
        episodes_file = cache / "episodes.jsonl"
        if not themes_file.is_file():
            return {**base, "available": False}
        try:
            themes = json.loads(themes_file.read_text())
            episodes = [
                json.loads(line)
                for line in episodes_file.read_text().splitlines()
                if line.strip()
            ]
        except (OSError, ValueError):
            return {**base, "available": False}
        total_lines = _count_steps(traj_dir / "trajectory.jsonl")
        return {
            **base,
            "available": True,
            "themes": themes,
            "episodes": episodes,
            "new_steps": max(0, total_lines - int(themes.get("raw_end_line") or 0)),
        }

    @app.post("/api/identities/{identity_id}/recap/refresh", status_code=202)
    def identity_recap_refresh(identity_id: str, body: RecapRefreshBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        _root_traj_dir_or_404(identity)
        cache_lock = None
        traj_dir = discovery.find_root_traj_dir(identity)
        if traj_dir is not None:
            cache_lock = traj_dir / "recap" / ".lock"
        if cache_lock is not None and cache_lock.is_dir():
            raise HTTPException(status_code=409, detail="A recap is already running")
        return control.recap_refresh(root, identity, body.rebuild)

    @app.get("/api/identities/{identity_id}/usage")
    def identity_usage(identity_id: str) -> dict:
        """Serve the cached per-day usage series (never computes — see
        usage.py; POST .../usage/refresh brings it up to date)."""
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        return usage.summary(traj_dir, identity.id, identity.name,
                             ledger=usage.ledger_path(identity.path))

    @app.post("/api/identities/{identity_id}/usage/refresh", status_code=202)
    def identity_usage_refresh(identity_id: str, body: UsageRefreshBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        if not usage.start_refresh(traj_dir, identity.name,
                                   ledger=usage.ledger_path(identity.path), rebuild=body.rebuild):
            raise HTTPException(status_code=409, detail="A usage refresh is already running")
        return {"ok": True, "action": "usage-refresh", "rebuild": body.rebuild}

    @app.get("/api/identities/{identity_id}/thinkers")
    def identity_thinkers(identity_id: str) -> dict:
        identity = _identity_or_404(root, identity_id)
        result = thinkers.thinkers_status(identity.path)
        for entry in result["thinkers"]:
            entry["log_mtime"] = _iso(entry["log_mtime"])
        result["identity"] = {"id": identity.id, "name": identity.name}
        return result

    @app.get("/api/identities/{identity_id}/thinker-sync")
    def thinker_sync_status(identity_id: str) -> dict:
        identity = _identity_or_404(root, identity_id)
        return thinker_sync.status(identity.path)

    @app.post("/api/identities/{identity_id}/thinker-sync")
    def thinker_sync_pull(identity_id: str, body: ThinkerSyncBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        for name in body.names:
            if not thinker_sync.SYNC_NAME_RE.match(name):
                raise HTTPException(status_code=422, detail=f"Invalid thinker name: {name}")
        try:
            return thinker_sync.sync(identity.path, body.names)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/identities/{identity_id}/thinkers/start")
    def thinkers_start(identity_id: str, body: ThinkerActionBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        enabled = thinkers.list_thinker_dirs(identity.path)
        if not enabled:
            raise HTTPException(status_code=409, detail="Identity has no thinkers")
        _checked_thinker_names(identity, body.names)
        # Expand "start all" to explicit names: the CLI's named-start path
        # kicks each thinker once with a manual-trigger step, while its
        # start-all path only arms the dispatcher — thinkers would then sit
        # idle until some new trajectory step happens to arrive.
        names = body.names or [d.name for d in enabled]
        return control.thinkers_start(root, identity, names, body.no_self_trigger)

    @app.post("/api/identities/{identity_id}/thinkers/stop")
    def thinkers_stop(identity_id: str, body: ThinkerActionBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        _checked_thinker_names(identity, body.names)
        return control.thinkers_stop(root, identity, body.names, body.force)

    @app.post("/api/identities/{identity_id}/thinkers/{name}/step", status_code=202)
    def thinkers_step(identity_id: str, name: str) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        _checked_thinker_names(identity, [name])
        return control.thinkers_step(root, identity, name)

    def _thinker_dir_or_404(identity: discovery.IdentityInfo, name: str) -> Path:
        if not safety.THINKER_NAME_RE.match(name):
            raise HTTPException(status_code=422, detail=f"Invalid thinker name: {name}")
        for tdir in thinkers.list_thinker_dirs(identity.path, include_disabled=True):
            if tdir.name == name:
                return tdir
        raise HTTPException(status_code=404, detail=f"Thinker not found: {name}")

    @app.post("/api/identities/{identity_id}/thinkers/{name}/disable")
    def thinkers_disable(identity_id: str, name: str) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        tdir = _thinker_dir_or_404(identity, name)
        status = thinkers.thinkers_status(identity.path)
        entry = next(t for t in status["thinkers"] if t["name"] == name)
        stopped = False
        if entry["state"] not in ("stopped", "disabled"):
            control.thinkers_stop(root, identity, [name])
            stopped = True
        (tdir / "disabled").touch()
        return {"ok": True, "name": name, "disabled": True, "stopped_first": stopped}

    @app.post("/api/identities/{identity_id}/thinkers/{name}/enable")
    def thinkers_enable(identity_id: str, name: str) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        tdir = _thinker_dir_or_404(identity, name)
        (tdir / "disabled").unlink(missing_ok=True)
        # The dispatcher builds its subscription map at startup; a thinker
        # enabled while it runs won't receive events until a restart.
        dispatcher_running = thinkers.thinkers_status(identity.path)["dispatcher"]["running"]
        return {
            "ok": True,
            "name": name,
            "disabled": False,
            "needs_restart": dispatcher_running,
        }

    @app.get("/api/identities/{identity_id}/chat")
    def identity_chat(
        identity_id: str,
        tail: int = Query(default=200, ge=1, le=2000),
        with_: str | None = Query(default=None, alias="with"),
    ) -> dict:
        identity = _identity_or_404(root, identity_id)
        traj_dir = _root_traj_dir_or_404(identity)
        if with_ is not None and not safety.CHAT_FROM_RE.match(with_):
            raise HTTPException(status_code=422, detail="Invalid conversation name")
        status = liveness.identity_status(identity.path, traj_dir / "trajectory.jsonl")
        view = chat.chat_view(
            trajectory.CACHE.chat_steps(traj_dir),
            identity.name,
            tail,
            with_,
            chat.active_partial_replies(identity.path, identity.name, with_),
        )
        return {
            "identity": {"id": identity.id, "name": identity.name},
            "live": status["live"],
            "messages": view["messages"],
            "outcomes": view["outcomes"],
        }

    @app.post("/api/identities/{identity_id}/chat")
    def identity_chat_send(identity_id: str, body: ChatSendBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        if not body.content.strip():
            raise HTTPException(status_code=422, detail="Empty message")
        if not safety.CHAT_FROM_RE.match(body.from_name):
            raise HTTPException(status_code=422, detail="Invalid sender name")
        if body.source_url is not None and not safety.is_slack_permalink(body.source_url):
            raise HTTPException(status_code=422, detail="Invalid source URL")
        return control.chat_send(
            root, identity, body.content, body.from_name, body.source_url
        )

    # -- Web push ----------------------------------------------------------
    # Keys/subscriptions live in <root>/.web-push; the sender thread is
    # started by cli.py in production, not here (tests stay thread-free).

    @app.get("/api/push/key")
    def push_key() -> dict:
        return {"key": push.vapid_public_key(root)}

    @app.post("/api/push/subscriptions")
    def push_subscribe(body: PushSubscribeBody) -> dict:
        _require_controls()
        if not body.name.startswith(push.SUBSCRIBABLE_PREFIX) or not safety.CHAT_FROM_RE.match(body.name):
            raise HTTPException(status_code=422, detail="Invalid sender name")
        if not body.subscription.get("endpoint", "").startswith("https://"):
            raise HTTPException(status_code=422, detail="Invalid subscription")
        count = push.add_subscription(root, body.name, body.subscription)
        return {"ok": True, "name": body.name, "subscriptions": count}

    @app.post("/api/push/unsubscribe")
    def push_unsubscribe(body: PushUnsubscribeBody) -> dict:
        _require_controls()
        removed = push.remove_subscription(root, body.endpoint)
        return {"ok": True, "removed": removed}

    # -- Import / export ---------------------------------------------------
    # Archives are produced/consumed by `identity export` / `identity import`
    # (tools/identity); the endpoints only move bytes. Export stays available in
    # read-only mode: it reveals nothing the viewer doesn't already show, and
    # it doubles as the backup path.

    def _export_download(tmp: Path, basename: str) -> FileResponse:
        safe = re.sub(r"[^A-Za-z0-9._-]", "-", basename) or "identity"
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        return FileResponse(
            tmp,
            media_type="application/gzip",
            filename=f"{safe}-{stamp}.shellm.tgz",
            background=BackgroundTask(tmp.unlink, missing_ok=True),
        )

    @app.get("/api/identities/{identity_id}/export")
    def export_identity(
        identity_id: str,
        soul_only: bool = Query(default=False),
        slim: bool = Query(default=False),
    ) -> FileResponse:
        identity = _identity_or_404(root, identity_id)
        tmp = control.identity_export(root, identity, soul_only, slim)
        return _export_download(tmp, identity.name)

    # Export jobs: the synchronous GET above builds the archive before it
    # sends a byte, which for a big mind log means a minute of silence and,
    # behind Cloudflare, a 524 at 100s. The dash instead POSTs a job, polls
    # its status, then downloads the finished file (streamed, fast). One job
    # per identity builds at a time; the last EXPORT_JOBS_KEPT finished ones
    # stay listed (and their files on disk) until deleted or evicted, so a
    # viewer who navigated away finds the archive when they come back. The
    # list lives in process memory: a web restart forgets it and leaves the
    # files for the tmp cleaner.
    EXPORT_JOBS_KEPT = 5
    export_jobs: dict[str, dict] = {}
    export_jobs_lock = threading.RLock()

    def _export_job_public(job: dict) -> dict:
        elapsed = (datetime.now(timezone.utc) - job["started"]).total_seconds()
        out = {
            "job_id": job["id"],
            "identity_id": job["identity_id"],
            "status": job["status"],
            "soul_only": job["soul_only"],
            "slim": job["slim"],
            "started_at": job["started"].isoformat(),
            "seconds": round(job.get("seconds", elapsed), 1),
            "size": job.get("size"),
            "filename": job.get("filename"),
            "error": job.get("error"),
        }
        if job["status"] == "done":
            out["download_url"] = f"/api/export-jobs/{job['id']}/download"
        return out

    def _drop_export_job(job: dict) -> None:
        path = job.get("path")
        if path:
            Path(path).unlink(missing_ok=True)

    def _run_export_job(job: dict, identity: discovery.IdentityInfo) -> None:
        try:
            tmp = control.identity_export(root, identity, job["soul_only"], job["slim"])
        except HTTPException as exc:
            detail = exc.detail
            msg = detail.get("message") if isinstance(detail, dict) else str(detail)
            with export_jobs_lock:
                job["status"], job["error"] = "failed", msg or "export failed"
                job["seconds"] = (datetime.now(timezone.utc) - job["started"]).total_seconds()
            return
        except Exception as exc:  # noqa: BLE001 - surfaced to the poller
            with export_jobs_lock:
                job["status"], job["error"] = "failed", str(exc)
                job["seconds"] = (datetime.now(timezone.utc) - job["started"]).total_seconds()
            return
        with export_jobs_lock:
            job["path"] = str(tmp)
            job["size"] = tmp.stat().st_size
            job["status"] = "done"
            job["seconds"] = (datetime.now(timezone.utc) - job["started"]).total_seconds()

    def _identity_export_jobs(identity_id: str) -> list[dict]:
        # newest first; caller holds the lock
        return sorted(
            (j for j in export_jobs.values() if j["identity_id"] == identity_id),
            key=lambda j: j["started"],
            reverse=True,
        )

    class ExportJobRequest(BaseModel):
        soul_only: bool = False
        slim: bool = False

    @app.post("/api/identities/{identity_id}/export-jobs", status_code=202)
    def start_export_job(identity_id: str, body: ExportJobRequest | None = None) -> dict:
        identity = _identity_or_404(root, identity_id)
        body = body or ExportJobRequest()
        with export_jobs_lock:
            for other in export_jobs.values():
                if other["identity_id"] == identity_id and other["status"] == "running":
                    raise HTTPException(
                        status_code=409, detail="An export is already building"
                    )
            for old in _identity_export_jobs(identity_id)[EXPORT_JOBS_KEPT - 1 :]:
                _drop_export_job(export_jobs.pop(old["id"]))
            safe = re.sub(r"[^A-Za-z0-9._-]", "-", identity.name) or "identity"
            stamp = datetime.now(timezone.utc)
            flavour = "-slim" if body.slim else ""
            flavour += "-soul" if body.soul_only else ""
            job = {
                "id": uuid.uuid4().hex,
                "identity_id": identity_id,
                "status": "running",
                "soul_only": body.soul_only,
                "slim": body.slim,
                "started": stamp,
                "filename": f"{safe}{flavour}-{stamp.strftime('%Y%m%d-%H%M%S')}.shellm.tgz",
            }
            export_jobs[job["id"]] = job
        threading.Thread(
            target=_run_export_job, args=(job, identity), daemon=True
        ).start()
        return _export_job_public(job)

    @app.get("/api/identities/{identity_id}/export-jobs")
    def list_export_jobs(identity_id: str) -> list[dict]:
        _identity_or_404(root, identity_id)
        with export_jobs_lock:
            return [_export_job_public(j) for j in _identity_export_jobs(identity_id)]

    @app.delete("/api/export-jobs/{job_id}")
    def delete_export_job(job_id: str) -> dict:
        with export_jobs_lock:
            job = _export_job_or_404(job_id)
            if job["status"] == "running":
                raise HTTPException(status_code=409, detail="Export is still building")
            _drop_export_job(export_jobs.pop(job_id))
        return {"ok": True, "job_id": job_id}

    def _export_job_or_404(job_id: str) -> dict:
        with export_jobs_lock:
            job = export_jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="No such export job")
        return job

    @app.get("/api/export-jobs/{job_id}")
    def export_job_status(job_id: str) -> dict:
        with export_jobs_lock:
            return _export_job_public(_export_job_or_404(job_id))

    @app.get("/api/export-jobs/{job_id}/download")
    def export_job_download(job_id: str) -> FileResponse:
        job = _export_job_or_404(job_id)
        if job["status"] != "done":
            raise HTTPException(status_code=409, detail=f"Export is {job['status']}")
        # The file stays until the next job for this identity, so a viewer
        # who tabbed away can come back and click again.
        return FileResponse(
            job["path"], media_type="application/gzip", filename=job["filename"]
        )

    @app.get("/api/export")
    def export_all_identities(soul_only: bool = Query(default=False)) -> FileResponse:
        tmp = control.identity_export_all(root, soul_only)
        return _export_download(tmp, "identities")

    @app.post("/api/identities/import", status_code=201)
    async def import_identities(
        request: Request, name: str | None = Query(default=None)
    ) -> dict:
        _require_controls()
        if name is not None and not safety.IDENTITY_NAME_RE.match(name):
            raise HTTPException(
                status_code=422,
                detail="Invalid identity name (use lowercase alphanumeric + hyphens)",
            )
        max_bytes = int(env.getenv("HEADLONG_WEB_MAX_IMPORT_MB", "512")) * 1024 * 1024
        fd, tmp_name = tempfile.mkstemp(suffix=".shellm.tgz")
        tmp = Path(tmp_name)
        total = 0
        first_chunk = b""
        try:
            with os.fdopen(fd, "wb") as out:
                async for chunk in request.stream():
                    if not first_chunk:
                        first_chunk = chunk
                    total += len(chunk)
                    if total > max_bytes:
                        raise HTTPException(
                            status_code=413,
                            detail=f"Archive exceeds HEADLONG_WEB_MAX_IMPORT_MB ({max_bytes // (1024 * 1024)} MB)",
                        )
                    out.write(chunk)
            if not first_chunk.startswith(b"\x1f\x8b"):
                raise HTTPException(
                    status_code=422, detail="Not a gzip archive (.shellm.tgz expected)"
                )
            return await run_in_threadpool(control.identity_import, root, tmp, name)
        finally:
            tmp.unlink(missing_ok=True)

    @app.post("/api/identities", status_code=201)
    def create_identity(body: NewIdentityBody) -> dict:
        _require_controls()
        if not safety.IDENTITY_NAME_RE.match(body.name):
            raise HTTPException(
                status_code=422,
                detail="Invalid identity name (use lowercase alphanumeric + hyphens)",
            )
        return control.identity_new(root, body.name)

    @app.post("/api/killall")
    def api_killall(body: KillallBody) -> dict:
        _require_controls()
        return control.killall(body.dry_run)

    # -- LLM health ---------------------------------------------------------

    @app.get("/api/llm-health")
    def llm_health_endpoint() -> dict:
        """Passive provider-health signals inferred from the mind logs
        (failure-marker steps + thought cadence). Free; briefly cached."""
        return llm_health.llm_health(root)

    @app.post("/api/llm-health/probe")
    def llm_probe_endpoint() -> dict:
        """Active check: one tiny real LLM call (costs a fraction of a cent)."""
        _require_controls()
        return control.llm_probe(root)

    @app.get("/api/openrouter/models")
    def openrouter_models() -> dict:
        """Model catalog for the config screen's model pickers (cached)."""
        return openrouter.available_models(root)

    @app.get("/api/identities/{identity_id}/env")
    def identity_env_get(identity_id: str) -> dict:
        identity = _identity_or_404(root, identity_id)
        own = [
            envfile.redacted_entry(key, value)
            for key, value in envfile.parse_env_file(identity.path / ".env")
        ]
        own_keys = {entry["key"] for entry in own}
        inherited = [
            {**envfile.redacted_entry(key, value), "overridden": key in own_keys}
            for key, value in envfile.parse_env_file(root / ".env")
        ]
        return {
            "identity": {"id": identity.id, "name": identity.name},
            "env": own,
            "inherited": inherited,
            "note": "Changes take effect the next time thinkers are started.",
        }

    @app.put("/api/identities/{identity_id}/env")
    def identity_env_put(identity_id: str, body: EnvVarBody) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        if not envfile.ENV_KEY_RE.match(body.key):
            raise HTTPException(
                status_code=422,
                detail="Invalid variable name (letters, digits, underscores)",
            )
        if any(ch in body.value for ch in "\n\r\x00"):
            raise HTTPException(status_code=422, detail="Value must be a single line")
        envfile.upsert_env_var(identity.path / ".env", body.key, body.value)
        return {"ok": True, **envfile.redacted_entry(body.key, body.value)}

    @app.delete("/api/identities/{identity_id}/env/{key}")
    def identity_env_delete(identity_id: str, key: str) -> dict:
        _require_controls()
        identity = _identity_or_404(root, identity_id)
        if not envfile.ENV_KEY_RE.match(key):
            raise HTTPException(status_code=422, detail="Invalid variable name")
        removed = envfile.delete_env_var(identity.path / ".env", key)
        if not removed:
            raise HTTPException(status_code=404, detail="Variable not found")
        return {"ok": True, "key": key}

    # Static frontend (registered last so /api wins)
    if static_dir and static_dir.exists():
        assets_dir = static_dir / "assets"
        if assets_dir.exists():
            app.mount("/assets", StaticFiles(directory=assets_dir), name="static_assets")

        @app.get("/favicon.ico")
        def favicon() -> FileResponse:
            return FileResponse(static_dir / "favicon.ico")

        # PWA files must bypass the SPA catch-all: the manifest and service
        # worker need their real bytes (and the SW needs root scope).
        @app.get("/manifest.webmanifest")
        def manifest() -> FileResponse:
            return FileResponse(
                static_dir / "manifest.webmanifest",
                media_type="application/manifest+json",
            )

        @app.get("/sw.js")
        def service_worker() -> FileResponse:
            # no-store: a cached service worker delays push/behavior updates
            # on installed apps by up to a day.
            return FileResponse(
                static_dir / "sw.js",
                media_type="text/javascript",
                headers={"Cache-Control": "no-store"},
            )

        # iOS probes this exact root path regardless of <link> tags.
        @app.get("/apple-touch-icon.png")
        def apple_touch_icon() -> FileResponse:
            return FileResponse(
                static_dir / "icons" / "apple-touch-icon.png", media_type="image/png"
            )

        @app.get("/icons/{name}")
        def icon(name: str) -> FileResponse:
            safety.checked_name(name, safety.ICON_NAME_RE)
            icon_path = safety.contained_path(static_dir / "icons", name)
            if not icon_path.is_file():
                raise HTTPException(status_code=404, detail="Not found")
            return FileResponse(icon_path, media_type="image/png")

        @app.get("/{path:path}")
        def serve_spa(path: str) -> FileResponse:
            return FileResponse(static_dir / "index.html")

    return app
