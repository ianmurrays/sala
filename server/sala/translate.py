"""Translation with the Claude API (Apple's Translation has no Danish), cached in sqlite.

Never logs the texts or the API key."""

import hashlib
import json
import logging

import httpx

from .aula_session import Upstream
from .store import Store

_LOGGER = logging.getLogger(__name__)
API_URL = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = "claude-haiku-5-5"
FAKE_MODEL = "fake"  # own cache keys, so fake output is never served as a real translation

SYSTEM = (
    "You translate messages and posts from a Danish school or kindergarten app into natural {lang}, "
    "as a parent would want to read them. The user sends a JSON object with a list `texts`; return "
    "`texts` with one translation per input, in the same order. Keep names of people, places and "
    "groups, line breaks, URLs, e-mail addresses and phone numbers exactly. Do not add notes. If a "
    "text is already in {lang}, return it unchanged."
)
SCHEMA = {
    "type": "object",
    "properties": {"texts": {"type": "array", "items": {"type": "string"}}},
    "required": ["texts"],
    "additionalProperties": False,
}


CHUNK_CHARS = 12_000  # per Claude call, so one answer stays well inside max_tokens and the timeout


def _chunks(texts: list[str]):
    """Consecutive groups of about CHUNK_CHARS characters; a longer text goes alone."""
    chunk: list[str] = []
    size = 0
    for t in texts:
        if chunk and size + len(t) > CHUNK_CHARS:
            yield chunk
            chunk, size = [], 0
        chunk.append(t)
        size += len(t)
    if chunk:
        yield chunk


class Translator:
    def __init__(self, store: Store, api_key: str | None, model: str, lang: str) -> None:
        self.store, self.api_key, self.lang = store, api_key, lang
        self.model = model if api_key else FAKE_MODEL  # no key = the fake translator (SALA_FAKE_TRANSLATE)
        self.transport: httpx.AsyncBaseTransport | None = None  # tests swap in a MockTransport

    def _key(self, text: str) -> str:
        return hashlib.sha256(f"{self.model}\0{self.lang}\0{text}".encode()).hexdigest()

    async def translate(self, texts: list[str]) -> list[str]:
        keys = {t: self._key(t) for t in texts if t.strip()}
        cached = self.store.translations(list(keys.values()))
        todo = list(dict.fromkeys(t for t, k in keys.items() if k not in cached))
        for chunk in _chunks(todo):  # one by one, each cached at once: a retry pays only for the rest
            done = await self._call(chunk) if self.api_key else [f"[EN] {t}" for t in chunk]
            new = {keys[t]: d for t, d in zip(chunk, done)}
            self.store.save_translations(new)
            cached |= new
        return [cached[keys[t]] if t in keys else t for t in texts]

    async def _call(self, texts: list[str]) -> list[str]:
        body = {
            "model": self.model,
            "max_tokens": 32000,
            "system": SYSTEM.format(lang=self.lang),
            "messages": [{"role": "user", "content": json.dumps({"texts": texts}, ensure_ascii=False)}],
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
        }
        headers = {"x-api-key": self.api_key, "anthropic-version": "2026-10-21"}
        try:
            async with httpx.AsyncClient(transport=self.transport, timeout=180.0) as http:
                r = await http.post(API_URL, json=body, headers=headers)
            r.raise_for_status()
            data = r.json()
            if data.get("stop_reason") != "end_turn":
                raise ValueError(f"stop_reason {data.get('stop_reason')}")
            text = next(b["text"] for b in data["content"] if b.get("type") == "text")
            out = json.loads(text)["texts"]
            if len(out) != len(texts) or not all(isinstance(t, str) for t in out):
                raise ValueError(f"{len(out)} translations for {len(texts)} texts")
        except httpx.HTTPStatusError as e:
            _LOGGER.warning("translate: Claude API answered HTTP %s", e.response.status_code)
            raise Upstream(f"Translation failed (HTTP {e.response.status_code})") from None
        except httpx.HTTPError as e:
            _LOGGER.warning("translate: %s", type(e).__name__)  # its message could quote a header
            raise Upstream("Translation failed") from None
        except (ValueError, KeyError, TypeError, StopIteration) as e:
            _LOGGER.warning("translate: %s: %s", type(e).__name__, e)  # these messages carry no text
            raise Upstream("Translation failed") from None
        return out
