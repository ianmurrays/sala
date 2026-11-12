"""SALA_DEBUG_SHAPES=1: log the structure of every Aula API call, never its content.

Each call logs one line: verb, Aula method, status, then the JSON body reduced to
its shape. Strings become ``str[n]`` (dates/times and a few enum-like keys stay
verbatim, URLs keep only their host), so names, message text and addresses never
reach the log. Numbers and booleans are kept: they are ids, counts and flags.
"""

import json
import logging
import re
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx

_LOGGER = logging.getLogger("sala.aula")
_MAX = 12000  # chars per log line

# Keys whose string values are enum-like and safe to show.
_SAFE_KEYS = {
    "status", "type", "kind", "activityType", "repeatPattern", "mailBoxOwnerType",
    "portalRole", "role", "state", "eventType", "notificationType", "module",
    "sensitivityLevel", "mediaType", "fileStatus", "relation", "institutionCode",
    "openingHoursType", "presenceStatus", "responseType", "method",
}
_DATEISH = re.compile(r"^\d{4}-\d\d-\d\d([T ][\d:.]+)?(Z|[+-]\d\d:?\d\d)?$|^\d\d:\d\d(:\d\d)?$")


def shape(value: Any, key: str | None = None) -> Any:
    if isinstance(value, dict):
        return {k: shape(v, k) for k, v in value.items()}
    if isinstance(value, list):
        if not value:
            return []
        # ponytail: first 2 items show the element shape; enough to spot field names.
        return [shape(v, key) for v in value[:2]] + ([f"…{len(value)} items"] if len(value) > 2 else [])
    if isinstance(value, str):
        if key in _SAFE_KEYS and len(value) <= 40:
            return value
        if _DATEISH.match(value):
            return value
        if value.startswith(("http://", "https://")):
            return f"url<{urlsplit(value).hostname}>"
        return f"str[{len(value)}]"
    return value  # int, float, bool, None


def _method(url: httpx.URL) -> str:
    return (parse_qs(url.query.decode()).get("method") or [url.path])[0]


def _body(raw: bytes) -> str:
    try:
        return json.dumps(shape(json.loads(raw)), ensure_ascii=False)[:_MAX]
    except (ValueError, UnicodeDecodeError):
        return f"<{len(raw)} bytes non-JSON>"


async def _on_request(request: httpx.Request) -> None:
    if request.method != "GET" and request.content:
        _LOGGER.info("aula → %s %s %s", request.method, _method(request.url), _body(request.content))


async def _on_response(response: httpx.Response) -> None:
    req = response.request
    if "json" not in response.headers.get("content-type", ""):
        _LOGGER.info("aula ← %s %s %s (%s)", req.method, _method(req.url), response.status_code,
                     response.headers.get("content-type", "?"))
        return
    await response.aread()
    _LOGGER.info("aula ← %s %s %s %s", req.method, _method(req.url), response.status_code, _body(response.content))


def attach(client: httpx.AsyncClient) -> None:
    client.event_hooks["request"].append(_on_request)
    client.event_hooks["response"].append(_on_response)


if __name__ == "__main__":
    s = shape({"status": {"code": 0, "message": "OK"}, "data": [{"id": 5, "name": "Oskar Hansen",
               "type": "child", "startDateTime": "2026-11-12T08:00:00+01:00",
               "file": {"url": "https://media.aula.dk/x?sig=secret"}}] * 3})
    assert s["data"][0]["name"] == "str[12]" and s["data"][0]["type"] == "child", s
    assert s["data"][0]["file"]["url"] == "url<media.aula.dk>" and s["data"][-1] == "…3 items", s
    assert s["status"]["message"] == "str[2]" and s["data"][0]["startDateTime"].startswith("2026"), s
    print("ok")
