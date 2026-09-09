import pytest

from headlong_telegram import outbound


@pytest.fixture(autouse=True)
def notices(monkeypatch):
    """Capture delivery notices instead of running bin/traj."""
    written = []

    def collect(serve_root, traj_path, step):
        written.append(step)

    monkeypatch.setattr(outbound, "append_step", collect)
    return written
