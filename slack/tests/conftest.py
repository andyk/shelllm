import pytest

from headlong_slack import outbound


@pytest.fixture(autouse=True)
def notices(monkeypatch):
    """Capture delivery notices instead of running bin/traj.

    Every test gets the list; tests that care assert on it, the rest ignore it.
    """
    written = []

    def collect(serve_root, traj_path, step):
        written.append(step)

    monkeypatch.setattr(outbound, "append_step", collect)
    return written
