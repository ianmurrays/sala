import time

import pytest
from fastapi.testclient import TestClient

TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    """A fresh fake-mode server (not logged in yet)."""
    monkeypatch.setenv("SALA_FAKE", "1")
    monkeypatch.setenv("SALA_TOKEN", TOKEN)
    monkeypatch.setenv("SALA_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SALA_FAKE_LOGIN_SECONDS", "0.2")
    from sala.app import app

    with TestClient(app) as c:
        yield c


@pytest.fixture
def api(client):
    """A fake-mode server after a (simulated) MitID login."""
    client.post("/auth/login", headers=AUTH)
    for _ in range(50):
        if client.get("/auth/status", headers=AUTH).json()["state"] == "ok":
            break
        time.sleep(0.05)
    else:
        raise AssertionError("fake login did not finish")
    return client


@pytest.fixture
def fake(api):
    return api.app.state.session.fake_aula
