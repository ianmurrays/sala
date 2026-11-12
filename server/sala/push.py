"""Push notifications via ntfy (Stage 3).

A background poller reads Aula through the same mapping code as the API and
publishes one ntfy notification per new item:

- direct message: the newest message of a thread whose participants are me
  plus exactly one other person, sent by that person
- important post: a post with ``isImportant``
- holiday request: an unanswered vacation registration (high priority when
  the deadline is 2 days away or less)
- login needed: while the session is ``needs_login`` or ``error``, every poll
  (and ``SessionManager.login_needed_hooks``, for an immediate attempt) tries to
  publish one notification per loss until ntfy accepts it. The loss marker is
  kept in sqlite and cleared on a successful login, so a restart while logged
  out does not notify again.

Who is in a thread comes from the raw ``messaging.getThreads`` row, read the
way the portal reads it (app.*.js ``getExtraRecipientsCount``): ``recipients``
minus those who left (``leaveTime``) and minus the thread's own mailbox owner
(me), plus ``extraRecipientsCount`` for recipients the row leaves out. When
that count is 0 the creator and the latest sender are added in case the list
omits them (otherwise they are likely among the extra ones), and all of my own
institution profile ids are removed. Exactly one person left = direct. A direct
thread whose newest sender can't be determined notifies as "New message".

Privacy: notifications carry titles only, never message or post bodies.

Seen-set: every item has a stable key in sqlite. Each kind is seeded silently
on its first successful fetch, so pre-existing items never notify (a failed
fetch is not an empty one); an item dated before its kind was seeded never
notifies either. An item is marked seen only after ntfy answers
2xx, so a failed publish is retried on the next poll.
"""

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from urllib.parse import urlsplit, urlunsplit

import httpx

from aula.utils.dates import aula_today
from aula.utils.mapping import get_in

from . import mapping as m
from .aula_session import AuthRequired, SessionManager, Upstream
from .store import Store

_LOGGER = logging.getLogger(__name__)

PRIORITY_DEFAULT = 3
PRIORITY_HIGH = 4
KINDS = ("message", "post", "holiday")
LOSS_MARKER = "login_loss"  # store state key: when the current session loss began


@dataclass
class Event:
    key: str
    title: str
    click: str
    tags: list[str] = field(default_factory=list)
    priority: int = PRIORITY_DEFAULT
    notify: bool = True  # False: just remember it (my own message, a group thread)
    at: datetime | None = None  # when it was sent, if known


def _owner_id(person: Any) -> Any:
    return get_in(person, "mailBoxOwner.id") if isinstance(person, dict) else None


def _others(raw: dict, mine: set[int]) -> tuple[dict[Any, dict], int]:
    """(other participants by mailbox id, count of others the row leaves out)."""
    latest = raw.get("latestMessage") or {}
    me_box = _owner_id(raw)
    extra = int(raw.get("extraRecipientsCount") or 0)
    people: dict[Any, dict] = {}
    for r in raw.get("recipients") or []:
        if isinstance(r, dict) and r.get("leaveTime") is None and _owner_id(r) is not None:
            people.setdefault(_owner_id(r), r)
    if extra == 0:  # otherwise they are likely among the extra recipients already
        for p in (raw.get("creator"), latest.get("sender")):
            if _owner_id(p) is not None:
                people.setdefault(_owner_id(p), p)
    others = {pid: p for pid, p in people.items() if pid not in mine and pid != me_box}
    return others, extra


def is_direct(raw: dict, mine: set[int]) -> bool:
    others, extra = _others(raw, mine)
    return len(others) + extra == 1


def message_event(raw: dict, mine: set[int], sender: dict | None = None) -> Event | None:
    """The event for one getThreads row's newest message, or None if unusable.

    ``notify`` is set only for a direct thread whose newest message is not
    from me (from the other person, or from an unknown sender: "New message").
    ``sender`` overrides ``latestMessage.sender`` (see collect).
    """
    latest = raw.get("latestMessage") or {}
    tid = raw.get("id")
    mid = latest.get("id") or latest.get("sendDateTime")
    if tid is None or not mid:
        return None
    others, extra = _others(raw, mine)
    direct = len(others) + extra == 1
    sender = sender or latest.get("sender")
    sender_id = _owner_id(sender)
    from_me = sender_id is not None and (sender_id in mine or sender_id == _owner_id(raw))
    notify = direct and not from_me
    name = m._sender_name(sender) if sender_id is not None else None
    return Event(
        key=f"message:{tid}:{mid}",
        title=f"New message from {name}" if name else "New message",
        click=f"sala://thread/{tid}",
        tags=["speech_balloon"],
        notify=notify,
        at=m.parse_api_datetime(latest.get("sendDateTime")),
    )


def post_event(post) -> Event | None:
    if not post.is_important:
        return None
    return Event(
        key=f"post:{post.id}",
        title=f"Important post: {post.title or 'Untitled'}",
        click="sala://today",
        tags=["loudspeaker"],
        at=post.timestamp,
    )


def holiday_event(reg, today) -> Event | None:
    if not reg.is_missing_answer:
        return None
    start, end = m._date(reg.start_date), m._date(reg.end_date)
    deadline = m._date(reg.response_deadline)
    title = f"Holiday request {m.date_range_label(start, end) if start else reg.title or ''}".rstrip()
    if deadline:
        title += f" · answer by {m._short_date(deadline)}"
    urgent = bool(deadline and (deadline - today).days <= 2)
    return Event(
        key=f"holiday:{reg.id}",
        title=title,
        click="sala://today",
        tags=["palm_tree"],
        priority=PRIORITY_HIGH if urgent else PRIORITY_DEFAULT,
    )


async def collect(session: SessionManager, client, seen=lambda key: False) -> dict[str, list[Event] | None]:
    """Current items per kind; None for a kind whose read failed. ``seen``
    lets it skip the extra thread read for messages already handled."""
    profile = await session.profile(client)
    mine = m.guardian_profile_ids(profile)

    async def latest_sender(raw: dict) -> dict | None:
        # latestMessage.sender is not confirmed for live getThreads rows; for a
        # direct thread without it, read the thread's newest shown message.
        latest = raw.get("latestMessage") or {}
        if _owner_id(latest.get("sender")) is not None or not is_direct(raw, mine):
            return None
        if seen(f"message:{raw.get('id')}:{latest.get('id') or latest.get('sendDateTime')}"):
            return None
        try:
            meta = await m._thread_meta(client, str(raw.get("id")))
        except Exception as e:  # noqa: BLE001 - one thread (even a 401) must not fail the kind
            _LOGGER.warning("push: thread %s read failed: %s", raw.get("id"), e)
            return None  # sender unknown: notifies as "New message"
        shown = [x for x in meta.get("messages") or [] if isinstance(x, dict) and x.get("messageType") in m._SHOWN_TYPES]
        return shown[0].get("sender") if shown else None

    async def messages():
        out = []
        for t in await client.get_message_threads():
            raw = t._raw or {}
            event = message_event(raw, mine, await latest_sender(raw))
            if event:
                out.append(event)
        return out

    async def posts():
        rows = await client.get_posts(profile.institution_profile_ids, limit=10)
        return [e for e in (post_event(p) for p in rows) if e]

    async def holidays():
        today = aula_today()
        regs = await client.get_vacation_registrations([c.id for c in profile.children])
        return [e for e in (holiday_event(r, today) for r in regs) if e]

    return {
        "message": await m._optional("push: threads", messages()),
        "post": await m._optional("push: posts", posts()),
        "holiday": await m._optional("push: holiday requests", holidays()),
    }


def _server_root(url: str) -> str:
    """NTFY_URL is the server root (topic goes in the JSON body); drop any path."""
    parts = urlsplit(url.strip())
    root = urlunsplit((parts.scheme, parts.netloc, "", "", ""))
    if parts.path.strip("/") or parts.query or parts.fragment:
        _LOGGER.error("NTFY_URL must be the ntfy server root, not %s; publishing to %s", url, root)
    return root


def _aware(dt: datetime) -> datetime:
    return dt if dt.tzinfo else dt.replace(tzinfo=m.TZ)


class Pusher:
    def __init__(
        self,
        session: SessionManager,
        store: Store,
        *,
        topic: str,
        url: str = "https://ntfy.sh",
        token: str | None = None,
        poll_seconds: float = 300,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.session, self.store = session, store
        self.topic, self.url, self.token = topic, _server_root(url), token
        self.poll_seconds = poll_seconds
        self._http = httpx.AsyncClient(transport=transport, timeout=10.0)
        self._task: asyncio.Task | None = None
        self._side_tasks: set[asyncio.Task] = set()
        self._login_lock = asyncio.Lock()

    # --- lifecycle -----------------------------------------------------------

    def start(self) -> None:
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        for task in (self._task, *self._side_tasks):
            if task and not task.done():
                task.cancel()
        await self._http.aclose()

    async def _loop(self) -> None:
        while True:
            try:
                await self.poll_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                _LOGGER.exception("push poll failed")
            await asyncio.sleep(self.poll_seconds)

    # --- publishing ----------------------------------------------------------

    async def publish(self, title: str, *, click: str, priority: int = PRIORITY_DEFAULT, tags: list[str] | None = None) -> bool:
        """POST one notification with ntfy's JSON API. True when ntfy accepted it.

        JSON publishing (POST to the server root with ``topic`` in the body)
        avoids HTTP header encoding for titles with æøå.
        """
        payload = {
            "topic": self.topic,
            "title": title,
            "message": title,  # titles only, never bodies
            "priority": priority,
            "tags": tags or [],
            "click": click,
        }
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        try:
            resp = await self._http.post(self.url, json=payload, headers=headers)
        except httpx.HTTPError as e:
            _LOGGER.warning("ntfy publish failed: %s", e)
            return False
        if not resp.is_success:
            _LOGGER.warning("ntfy publish refused: HTTP %s", resp.status_code)
            return False
        return True

    async def notify_login_needed(self) -> bool:
        """Publish the pending "Aula login needed" for the current loss, if any.

        One notification per loss: the loss marker is stored in sqlite and the
        notification is keyed on it (``login:<marker>``), marked seen only when
        ntfy accepts it. Never raises. True when a notification was sent now.
        """
        try:
            async with self._login_lock:
                if self.session.state not in ("needs_login", "error"):
                    return False
                marker = self.store.state(LOSS_MARKER)
                if marker is None:
                    marker = datetime.now(m.TZ).isoformat()
                    self.store.set_state(LOSS_MARKER, marker)
                key = f"login:{marker}"
                if self.store.seen(key):
                    return False
                async with asyncio.timeout(15):
                    ok = await self.publish("Aula login needed", click="sala://today", priority=PRIORITY_HIGH, tags=["warning"])
                if ok:
                    self.store.mark_seen([key])
                return ok
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - retried on the next poll
            _LOGGER.exception("push: login-needed notification failed")
            return False

    def on_login_needed(self) -> None:
        """login_needed_hooks entry: try at once in the background, never block
        the request. The poll loop retries until ntfy accepts it."""
        task = asyncio.create_task(self.notify_login_needed())
        self._side_tasks.add(task)
        task.add_done_callback(self._side_tasks.discard)

    def on_logged_in(self) -> None:
        """logged_in_hooks entry: the loss is over; the next one notifies again."""
        self.store.clear_state(LOSS_MARKER)

    # --- polling -------------------------------------------------------------

    async def poll_once(self) -> int:
        """One poll. Returns how many notifications ntfy accepted."""
        if self.session.state != "ok":
            return int(await self.notify_login_needed())
        try:
            found = await self.session.call(lambda client: collect(self.session, client, self.store.seen))
        except (AuthRequired, Upstream) as e:
            _LOGGER.info("push poll skipped: %s", type(e).__name__)
            return 0
        if any(found.get(kind) is not None for kind in KINDS):
            # Aula answered: the session works even if no login ran (e.g. a
            # restart with tokens that refresh again), so the loss is over.
            self.store.clear_state(LOSS_MARKER)
        sent = 0
        for kind in KINDS:
            events = found.get(kind)
            if events is None:
                continue  # read failed: neither seed nor notify
            seeded_at = self.store.seeded_at(kind)
            if seeded_at is None:
                self.store.mark_seen([e.key for e in events])
                self.store.mark_seeded(kind)
                _LOGGER.info("push: seeded %s (%d items, no notifications)", kind, len(events))
                continue
            for e in events:
                if self.store.seen(e.key):
                    continue
                # Older than seeding (e.g. slid into the fetched page when a
                # newer item was deleted): remember it, don't notify.
                if not e.notify or (e.at and _aware(e.at) < seeded_at):
                    self.store.mark_seen([e.key])
                    continue
                if await self.publish(e.title, click=e.click, priority=e.priority, tags=e.tags):
                    self.store.mark_seen([e.key])
                    sent += 1
        return sent
