#!/usr/bin/env python3
"""Aula's web portal bundle, for finding the API calls behind a portal feature.

The portal (www.aula.dk/portal/) is public JavaScript; every Aula call in it is a string like
"?method=presence.getVacationRegistrationResponse" next to the code that builds its params and
reads its answer. This downloads the bundle and searches it.

    scripts/aula-bundle.py fetch               # download into .cache/aula-bundle/ (again when Aula deploys)
    scripts/aula-bundle.py methods [filter]    # every ?method= name, with the chunks that use it
    scripts/aula-bundle.py show <text> [chars] # code around each occurrence of <text> (default 600 chars)

No login: only the public portal files are fetched.
"""

import re
import sys
import urllib.request
from pathlib import Path

BASE = "https://www.aula.dk"
DIR = Path(__file__).resolve().parent.parent / ".cache" / "aula-bundle"
METHOD = re.compile(r"\?method=([A-Za-z]+\.[A-Za-z0-9]+)")


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def chunks() -> list[Path]:
    files = sorted(DIR.glob("*.js"))
    if not files:
        sys.exit("No bundle yet: run scripts/aula-bundle.py fetch")
    return files


def fetch() -> None:
    DIR.mkdir(parents=True, exist_ok=True)
    for old in DIR.glob("*.js"):
        old.unlink()
    index = get(f"{BASE}/portal/").decode()
    # index.html lists every chunk (app.*.js and the numbered ones); there's no lazy chunk map.
    paths = sorted(set(re.findall(r'src="(/static/js/[^"]+\.js)"', index)))
    for p in paths:
        (DIR / Path(p).name).write_bytes(get(BASE + p))
        print(p)
    (DIR / "index.html").write_text(index)
    print(f"{len(paths)} chunks in {DIR}")


def methods(flt: str | None) -> None:
    found: dict[str, set[str]] = {}
    for f in chunks():
        for m in METHOD.findall(f.read_text(errors="replace")):
            found.setdefault(m, set()).add(f.name.split(".")[0])
    for name in sorted(found):
        if not flt or flt.lower() in name.lower():
            print(f"{name}  ({', '.join(sorted(found[name]))})")


def show(text: str, width: int) -> None:
    for f in chunks():
        s = f.read_text(errors="replace")
        for m in re.finditer(re.escape(text), s):
            snippet = s[max(0, m.start() - width // 2): m.end() + width // 2]
            # A little air so minified code reads: a line per statement and block.
            snippet = re.sub(r"([;{}])", r"\1\n", snippet)
            print(f"=== {f.name} @ {m.start()}\n{snippet}\n")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["fetch"]:
        fetch()
    elif args[:1] == ["methods"]:
        methods(args[1] if len(args) > 1 else None)
    elif args[:1] == ["show"] and len(args) >= 2:
        show(args[1], int(args[2]) if len(args) > 2 else 600)
    else:
        sys.exit(__doc__)
