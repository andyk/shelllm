import json
import threading
import time

from headlong_telegram.mindlog import find_trajectory, follow, read_new


def _append(path, obj, newline=True):
    with path.open("a") as f:
        f.write(json.dumps(obj) + ("\n" if newline else ""))


def test_read_new_only_complete_lines(tmp_path):
    traj = tmp_path / "trajectory.jsonl"
    traj.write_text("")
    steps, off = read_new(traj, 0)
    assert steps == [] and off == 0

    _append(traj, {"type": "message", "content": "one"})
    steps, off = read_new(traj, off)
    assert [s["content"] for s in steps] == ["one"]

    # Partial line is not consumed until its newline arrives.
    with traj.open("a") as f:
        f.write('{"type": "message", "content": "tw')
    steps, off2 = read_new(traj, off)
    assert steps == [] and off2 == off
    with traj.open("a") as f:
        f.write('o"}\n')
    steps, off = read_new(traj, off)
    assert [s["content"] for s in steps] == ["two"]


def test_read_new_skips_corrupt_lines(tmp_path):
    traj = tmp_path / "trajectory.jsonl"
    traj.write_text('not json\n{"type": "message", "content": "ok"}\n')
    steps, _ = read_new(traj, 0)
    assert [s["content"] for s in steps] == ["ok"]


def test_read_new_does_not_replay_a_rebuilt_file(tmp_path):
    """A shrunk file is a different log; resume at its end, do not re-send
    everything in it (2026-09-09 Telegram replay)."""
    traj = tmp_path / "trajectory.jsonl"
    _append(traj, {"content": "a"})
    _append(traj, {"content": "b"})
    _, off = read_new(traj, 0)
    traj.write_text('{"content": "fresh"}\n')
    steps, off2 = read_new(traj, off)
    assert steps == [] and off2 == traj.stat().st_size
    _append(traj, {"content": "after"})
    steps, _ = read_new(traj, off2)
    assert [s["content"] for s in steps] == ["after"]


def test_follow_ignores_a_cursor_from_another_trajectory(tmp_path):
    """The Telegram bridge's state dir is shared across identities: after an
    identity switch its cursor held the other log's (small) offset and the
    bridge replayed 1.5GB of Audel's history. A cursor names its trajectory
    and is ignored for any other."""
    other = tmp_path / "other.jsonl"
    other.write_text("x\n")
    traj = tmp_path / "trajectory.jsonl"
    for i in range(50):
        _append(traj, {"content": f"old {i}"})
    cursor = tmp_path / "cursor"
    cursor.write_text(f"2 {other.resolve()}")

    def _later():
        time.sleep(0.05)
        _append(traj, {"content": "new"})

    threading.Thread(target=_later, daemon=True).start()
    gen = follow(traj, cursor, poll_interval=0.01)
    try:
        assert next(gen)["content"] == "new"
        assert cursor.read_text().split()[1] == str(traj.resolve())
    finally:
        gen.close()


def test_follow_honours_its_own_cursor(tmp_path):
    traj = tmp_path / "trajectory.jsonl"
    _append(traj, {"content": "seen"})
    off = traj.stat().st_size
    _append(traj, {"content": "unseen"})
    cursor = tmp_path / "cursor"
    cursor.write_text(f"{off} {traj.resolve()}")
    gen = follow(traj, cursor, poll_interval=0.01)
    try:
        assert next(gen)["content"] == "unseen"
    finally:
        gen.close()


def test_follow_legacy_offset_only_cursor(tmp_path):
    traj = tmp_path / "trajectory.jsonl"
    _append(traj, {"content": "seen"})
    off = traj.stat().st_size
    _append(traj, {"content": "unseen"})
    cursor = tmp_path / "cursor"
    cursor.write_text(str(off))
    gen = follow(traj, cursor, poll_interval=0.01)
    try:
        assert next(gen)["content"] == "unseen"
    finally:
        gen.close()


def test_find_trajectory(tmp_path):
    identity = tmp_path / "audel"
    traj_dir = identity / "trajectories" / "deadbeef-mind"
    traj_dir.mkdir(parents=True)
    (traj_dir / "trajectory.jsonl").write_text("")
    (identity / "info.txt").write_text(
        "name=audel\nroot_trajectory=deadbeef-1234-5678-9abc-def012345678\n"
    )
    assert find_trajectory(identity) == traj_dir / "trajectory.jsonl"


def test_follow_creates_missing_cursor_parent(tmp_path):
    """Outbound used to FileNotFoundError if state_dir vanished mid-run.

    follow() starts at EOF when the cursor file is missing, so the new
    line has to arrive *after* the generator has taken its initial
    offset. Append from a thread so next() can observe it.
    """
    traj = tmp_path / "trajectory.jsonl"
    traj.write_text("")
    cursor = tmp_path / "missing-state" / "cursor"
    assert not cursor.parent.exists()

    def _later():
        time.sleep(0.05)
        _append(traj, {"content": "hello"})

    threading.Thread(target=_later, daemon=True).start()
    gen = follow(traj, cursor, poll_interval=0.01)
    try:
        step = next(gen)
        assert step["content"] == "hello"
        assert cursor.is_file()
        assert cursor.parent.is_dir()
    finally:
        gen.close()
