"""POST /translate and GET /features (API.md "Translation"), with the Claude API mocked."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from conftest import AUTH


class Claude:
    """A fake Messages API: "translates" by upper-casing, records each request."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.status = 200
        self.stop_reason = "end_turn"

    def handler(self, request: httpx.Request) -> httpx.Response:
        assert request.url == "https://api.anthropic.com/v1/messages"
        assert request.headers["x-api-key"] == "sk-test"
        assert request.headers["anthropic-version"] == "2026-10-21"
        body = json.loads(request.content)
        self.requests.append(body)
        if self.status != 200:
            return httpx.Response(self.status, json={"type": "error"})
        texts = json.loads(body["messages"][0]["content"])["texts"]
        out = json.dumps({"texts": [t.upper() for t in texts]})
        content = [{"type": "thinking", "thinking": "", "signature": "x"}, {"type": "text", "text": out}]
        return httpx.Response(200, json={"content": content, "stop_reason": self.stop_reason})

    def sent(self, i: int = -1) -> list[str]:
        return json.loads(self.requests[i]["messages"][0]["content"])["texts"]


@pytest.fixture
def claude(client, monkeypatch):
    """The server restarted with ANTHROPIC_API_KEY set, its Claude calls going to a `Claude`."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    fake = Claude()
    with TestClient(client.app) as c:
        c.app.state.translator.transport = httpx.MockTransport(fake.handler)
        fake.client = c
        yield fake


def _translate(c, texts):
    return c.post("/translate", headers=AUTH, json={"texts": texts})


def test_off_by_default(client):
    assert client.get("/features", headers=AUTH).json() == {"translate": False}
    r = _translate(client, ["Hej"])
    assert r.status_code == 404 and r.json() == {"error": "not_enabled"}
    assert _translate(client, ["x"] * 51).status_code == 404  # off wins over the limits
    assert client.post("/translate", headers=AUTH, json={"texts": "Hej"}).status_code == 404  # and over the schema


def test_translates_in_order_with_one_call(claude):
    c = claude.client
    assert c.get("/features", headers=AUTH).json() == {"translate": True}
    r = _translate(c, ["Hej", "", "med dig", "Hej"])
    assert r.status_code == 200, r.text
    assert r.json() == {"texts": ["HEJ", "", "MED DIG", "HEJ"]}
    assert len(claude.requests) == 1
    assert claude.sent() == ["Hej", "med dig"]  # empty and repeated texts are not sent
    req = claude.requests[0]
    assert req["model"] == "claude-haiku-5-5"
    assert req["output_config"]["format"]["type"] == "json_schema"
    assert "English" in req["system"]


def test_cache_hit_avoids_a_call(claude):
    c = claude.client
    _translate(c, ["Hej", "Farvel"])
    assert _translate(c, ["Farvel", "Hej"]).json() == {"texts": ["FARVEL", "HEJ"]}
    assert len(claude.requests) == 1
    assert _translate(c, ["Hej", "Ny tekst"]).json() == {"texts": ["HEJ", "NY TEKST"]}
    assert claude.sent() == ["Ny tekst"]  # only the uncached text


def test_limits(claude):
    c = claude.client
    assert _translate(c, ["x"] * 51).status_code == 400
    assert _translate(c, ["x" * 20_001]).status_code == 400
    assert _translate(c, ["x" * 20_000] + ["y"] * 49).status_code == 200
    assert c.post("/translate", headers=AUTH, json={"texts": "Hej"}).status_code == 400
    assert c.post("/translate", json={"texts": ["Hej"]}).status_code == 401


@pytest.mark.parametrize("status,stop_reason", [(529, "end_turn"), (400, "end_turn"), (200, "max_tokens"), (200, "refusal")])
def test_upstream_failure_is_502_and_not_cached(claude, status, stop_reason):
    claude.status, claude.stop_reason = status, stop_reason
    r = _translate(claude.client, ["Hej"])
    assert r.status_code == 502 and r.json()["error"] == "upstream"
    assert "Hej" not in r.text
    claude.status, claude.stop_reason = 200, "end_turn"
    assert _translate(claude.client, ["Hej"]).json() == {"texts": ["HEJ"]}
    assert len(claude.requests) == 2


def test_large_batches_are_chunked_and_each_chunk_cached(claude):
    a, b, c, big = "a" * 5000, "b" * 5000, "c" * 5000, "d" * 15000
    fail_on = {"n": 3}
    handler = claude.handler

    def flaky(request):
        if len(claude.requests) + 1 == fail_on["n"]:
            claude.requests.append(json.loads(request.content))
            return httpx.Response(529)
        return handler(request)

    claude.client.app.state.translator.transport = httpx.MockTransport(flaky)
    assert _translate(claude.client, [a, b, c, big, "e"]).status_code == 502
    assert [claude.sent(i) for i in range(3)] == [[a, b], [c], [big]]  # ~12k chars each; big goes alone
    fail_on["n"] = 0
    r = _translate(claude.client, [a, b, c, big, "e"])
    assert r.json() == {"texts": [a.upper(), b.upper(), c.upper(), big.upper(), "E"]}
    assert [claude.sent(i) for i in (3, 4)] == [[big], ["e"]]  # the first two chunks stayed cached
    assert len(claude.requests) == 5


def test_wrong_count_is_502(claude, monkeypatch):
    def short(request):
        out = json.dumps({"texts": ["ONE"]})
        return httpx.Response(200, json={"content": [{"type": "text", "text": out}], "stop_reason": "end_turn"})

    claude.client.app.state.translator.transport = httpx.MockTransport(short)
    assert _translate(claude.client, ["en", "to"]).status_code == 502


def test_read_only_mode_allows_translate(claude, monkeypatch):
    monkeypatch.setenv("SALA_READ_ONLY", "1")
    assert _translate(claude.client, ["Hej"]).status_code == 200


def test_fake_translator(client, monkeypatch):
    monkeypatch.setenv("SALA_FAKE_TRANSLATE", "1")
    with TestClient(client.app) as c:
        assert c.get("/features", headers=AUTH).json() == {"translate": True}
        assert _translate(c, ["Hej", ""]).json() == {"texts": ["[EN] Hej", ""]}
