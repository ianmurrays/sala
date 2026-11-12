"""SQLite store: APNs device tokens and the attachment id -> URL map."""

import sqlite3
import threading
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
                CREATE TABLE IF NOT EXISTS devices (
                    token TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS attachments (
                    id TEXT PRIMARY KEY,
                    url TEXT NOT NULL,
                    name TEXT NOT NULL,
                    seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """
            )

    def add_device(self, token: str) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO devices (token) VALUES (?)", (token,))

    def devices(self) -> list[str]:
        with self._lock:
            return [r[0] for r in self._db.execute("SELECT token FROM devices")]

    def register_attachment(self, url: str, name: str) -> str:
        """Remember an Aula attachment URL and return the opaque id for it."""
        att_id = attachment_id(url)
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO attachments (id, url, name) VALUES (?, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET name = excluded.name, seen_at = CURRENT_TIMESTAMP",
                (att_id, url, name),
            )
        return att_id

    def attachment(self, att_id: str) -> tuple[str, str] | None:
        with self._lock:
            row = self._db.execute("SELECT url, name FROM attachments WHERE id = ?", (att_id,)).fetchone()
        return (row[0], row[1]) if row else None

    def close(self) -> None:
        self._db.close()
