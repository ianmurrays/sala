"""SQLite store: the attachment id -> URL map, the push seen-set and cached translations."""

import sqlite3
import threading
from datetime import UTC, datetime
from pathlib import Path

from .mapping import attachment_id


class Store:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock, self._db:
            self._db.executescript(
                """
                DROP TABLE IF EXISTS devices;
                CREATE TABLE IF NOT EXISTS attachments (
                    id TEXT PRIMARY KEY,
                    url TEXT NOT NULL,
                    name TEXT NOT NULL,
                    seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                -- push: items already notified (or seeded), and kinds seeded once
                CREATE TABLE IF NOT EXISTS push_seen (
                    key TEXT PRIMARY KEY,
                    seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS push_seeded (
                    kind TEXT PRIMARY KEY,
                    seeded_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                -- push: small named values (e.g. the current session-loss marker)
                CREATE TABLE IF NOT EXISTS push_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                -- translate: sha256(model, lang, text) -> translation
                CREATE TABLE IF NOT EXISTS translations (
                    key TEXT PRIMARY KEY,
                    text TEXT NOT NULL
                );
                """
            )

    def register_attachment(self, url: str, name: str, key: str | None = None) -> str:
        """Remember an Aula attachment URL and return the opaque id for it.

        The id hashes ``key`` (default: the URL). Re-registering an id stores
        the newest URL, so a stable key keeps one id across signed URLs."""
        att_id = attachment_id(key or url)
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO attachments (id, url, name) VALUES (?, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET url = excluded.url, name = excluded.name, seen_at = CURRENT_TIMESTAMP",
                (att_id, url, name),
            )
        return att_id

    def attachment(self, att_id: str) -> tuple[str, str] | None:
        with self._lock:
            row = self._db.execute("SELECT url, name FROM attachments WHERE id = ?", (att_id,)).fetchone()
        return (row[0], row[1]) if row else None

    def seen(self, key: str) -> bool:
        with self._lock:
            return self._db.execute("SELECT 1 FROM push_seen WHERE key = ?", (key,)).fetchone() is not None

    def mark_seen(self, keys: list[str]) -> None:
        with self._lock, self._db:
            self._db.executemany("INSERT OR IGNORE INTO push_seen (key) VALUES (?)", [(k,) for k in keys])

    def seeded(self, kind: str) -> bool:
        with self._lock:
            return self._db.execute("SELECT 1 FROM push_seeded WHERE kind = ?", (kind,)).fetchone() is not None

    def seeded_at(self, kind: str) -> datetime | None:
        with self._lock:
            row = self._db.execute("SELECT seeded_at FROM push_seeded WHERE kind = ?", (kind,)).fetchone()
        return datetime.fromisoformat(row[0]).replace(tzinfo=UTC) if row else None

    def mark_seeded(self, kind: str) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO push_seeded (kind) VALUES (?)", (kind,))

    def state(self, key: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT value FROM push_state WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set_state(self, key: str, value: str) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR REPLACE INTO push_state (key, value) VALUES (?, ?)", (key, value))

    def clear_state(self, key: str) -> None:
        with self._lock, self._db:
            self._db.execute("DELETE FROM push_state WHERE key = ?", (key,))

    def translations(self, keys: list[str]) -> dict[str, str]:
        with self._lock:
            return {
                k: t
                for k in keys
                for (t,) in self._db.execute("SELECT text FROM translations WHERE key = ?", (k,)).fetchall()
            }

    def save_translations(self, items: dict[str, str]) -> None:
        with self._lock, self._db:
            self._db.executemany("INSERT OR REPLACE INTO translations (key, text) VALUES (?, ?)", items.items())

    def close(self) -> None:
        self._db.close()
