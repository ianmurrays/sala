"""The fake answers with fields live Aula sends, where live Aula sends them.

A fake that invents a field (say a picture on a thread's creator, which live
getThreads only has on recipients) keeps tests green while the app shows
nothing. aula_shapes/<method>.json holds each read's live structure, types
only: no names, ids, dates or text. To refresh them:

    SALA_DEBUG_SHAPES=1 scripts/run-worktree.sh      # from a worktree
    # use the app, or curl the read routes
    docker compose -p sala-<worktree> logs --no-log-prefix | PYTHONPATH=. uv run python tests/test_aula_shapes.py
"""

import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from conftest import AUTH
from sala.debuglog import shape

SHAPES = Path(__file__).parent / "aula_shapes"


def skeleton(value):
    """A debuglog shape reduced to structure: dicts keep keys, lists merge their items, scalars become type names."""
    if isinstance(value, dict):
        return {k: skeleton(v) for k, v in value.items()}
    if isinstance(value, list):
        items = [skeleton(v) for v in value if not (isinstance(v, str) and v.startswith("…"))]
        return [merge(items)] if items else []
    return "null" if value is None else type(value).__name__


def merge(items):
    out = items[0]
    for item in items[1:]:
        if isinstance(out, dict) and isinstance(item, dict):
            out = {k: merge([out[k], item[k]]) if k in out and k in item else out.get(k, item.get(k)) for k in out | item}
        elif out == "null":
            out = item
    return out


def invented(fake, live, path="data"):
    """Paths the fake sends that live Aula doesn't. A live null or empty list says nothing about what's inside."""
    if isinstance(fake, dict) and isinstance(live, dict):
        for k, v in fake.items():
            if k not in live:
                yield f"{path}.{k}"
            else:
                yield from invented(v, live[k], f"{path}.{k}")
    elif isinstance(fake, list) and isinstance(live, list) and fake and live:
        yield from invented(fake[0], live[0], path + "[]")


def test_fake_sends_only_fields_live_aula_sends(api, fake, monkeypatch):
    seen = {}
    request = fake.request

    async def recording(method, url, **kw):
        response = await request(method, url, **kw)
        name = (kw.get("params") or {}).get("method") or parse_qs(urlsplit(url).query).get("method", [""])[0]
        seen[name] = response.data
        return response

    monkeypatch.setattr(fake, "request", recording)
    today = api.get("/today", headers=AUTH).json()
    thread = api.get("/threads", headers=AUTH).json()[0]["id"]
    for path in ("/posts?page=2", "/threads?page=1", f"/threads/{thread}", "/folders", "/albums", "/albums/6001/photos",
                 f"/children/{today['children'][0]['id']}/pickup"):
        assert api.get(path, headers=AUTH).status_code == 200, path

    checked = {p.stem for p in SHAPES.glob("*.json")} & seen.keys()
    assert len(checked) >= 10, f"only {sorted(checked)} have live shapes"
    problems = [
        f"{method}: {p}"
        for method in sorted(checked)
        for p in invented(skeleton(shape(seen[method]["data"])), json.loads((SHAPES / f"{method}.json").read_text()))
    ]
    assert not problems, "the fake sends fields live Aula doesn't:\n" + "\n".join(problems)


if __name__ == "__main__":
    # Read `docker compose logs` of a SALA_DEBUG_SHAPES=1 server; write each GET's newest live shape.
    found = {}
    for line in sys.stdin:
        _, sep, rest = line.partition("aula ← GET ")
        method, _, rest = rest.partition(" ")
        status, _, body = rest.partition(" ")
        if sep and status == "200" and body.startswith("{"):
            try:
                found[method] = skeleton(json.loads(body)["data"])
            except (ValueError, KeyError):
                print(f"skipped {method}: body cut off or not Aula's envelope", file=sys.stderr)
    SHAPES.mkdir(exist_ok=True)
    for method, data in found.items():
        (SHAPES / f"{method}.json").write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
    print(f"wrote {len(found)} shapes: {', '.join(sorted(found))}")
