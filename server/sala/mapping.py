"""Aula -> API.md shapes, plus the Aula reads and writes the routes need.

Everything here takes an ``AulaApiClient``; the session manager decides which
client (real or fake-backed) and turns auth failures into 503s.

Calls the library has no method for go through ``client._request_with_version_retry``
so API-version bumps and token refresh are shared with the library's own calls.
"""

import asyncio
import hashlib
import html
import logging
import mimetypes
import os
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Any
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

import httpx
from aula import AulaApiClient
from aula.http import AulaAuthenticationError, AulaInvalidTokenError, AulaSessionExpiredError, HttpRequestError
from aula.models import ActivityType, Child, PresenceModule, PresenceState, Profile
from aula.models.attachment import Attachment, parse_attachments
from aula.utils.dates import aula_today, parse_api_datetime
from aula.utils.html import html_to_plain
from aula.utils.mapping import get_in

_LOGGER = logging.getLogger(__name__)
TZ = ZoneInfo("Europe/Copenhagen")

# Register an attachment URL server-side; returns the opaque id to hand out.
Register = Callable[[str, str], str]


def auth_error(err: BaseException) -> bool:
    """Aula refused us (HTTP 401/403 or an auth sub-code), after the library's refresh.

    The library raises AulaRejectedError (not AulaAuthenticationError) when a
    401/403 body carries a non-zero status code, so the HTTP status is checked too.
    """
    return isinstance(err, AulaAuthenticationError) or (
        isinstance(err, HttpRequestError) and err.status_code in (401, 403)
    )


def session_gone(err: BaseException) -> bool:
    """Errors that clearly mean the Aula session itself is dead."""
    if isinstance(err, (AulaSessionExpiredError, AulaInvalidTokenError)):
        return True
    return isinstance(err, HttpRequestError) and err.status_code == 401


class BadRequest(Exception):
    """The request is valid JSON but makes no sense against Aula's data (-> 400)."""


class NotFound(Exception):
    """Unknown child, thread or message (-> 404)."""


class UpstreamFailure(Exception):
    """Aula answered but did not do what was asked (-> 502)."""


class Conflict(Exception):
    """The write makes no sense in today's state, e.g. a pickup on a day off (-> 409)."""


# --- small helpers -----------------------------------------------------------


def now() -> datetime:
    return datetime.now(TZ)


def hhmm(value: Any) -> str | None:
    """'16:15', '16:15:00' or '2026-11-12T16:15:00+01:00' -> '16:15'."""
    if not value or not isinstance(value, str):
        return None
    t = value.split("T")[-1][:5]
    return t if len(t) == 5 and t[2] == ":" else None


def iso(value: Any) -> str | None:
    """Aula timestamp (aware, Z or naive) -> ISO 8601 with offset."""
    dt = value if isinstance(value, datetime) else parse_api_datetime(value)
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TZ)
    return dt.astimezone(TZ).isoformat(timespec="seconds")


def plain(html_text: str) -> str:
    """Aula HTML -> plain text (library converter, minus markdown hard-break spaces)."""
    return "\n".join(line.rstrip() for line in html_to_plain(html_text or "").split("\n")).strip()


def text_to_html(text: str) -> str:
    """Plain text from the app -> the HTML Aula's editor would send.

    The portal's reply box holds editor HTML (it runs ``stripHTML(this.message)``
    before validating length), so a plain string would show up unformatted.
    """
    paragraphs = [p for p in text.replace("\r\n", "\n").split("\n\n") if p.strip()]
    return "".join(
        "<p>" + "<br>".join(html.escape(line) for line in p.split("\n")) + "</p>" for p in paragraphs
    )


def guardian_profile_ids(profile: Profile) -> set[int]:
    """The user's own institution profile ids (not the children's)."""
    raw = profile._raw or {}
    return {ip["id"] for ip in raw.get("institutionProfiles") or [] if isinstance(ip, dict) and "id" in ip}


def find_child(profile: Profile, child_id: int) -> Child:
    for child in profile.children:
        if child.id == child_id:
            return child
    raise NotFound(f"child {child_id}")


def _short_date(d: date) -> str:
    return f"{d.day} {d.strftime('%b')}"


def date_range_label(start: date, end: date | None) -> str:
    """21–23 Dec, 30 Dec – 2 Jan, 21 Dec."""
    if end is None or end == start:
        return _short_date(start)
    if (start.year, start.month) == (end.year, end.month):
        return f"{start.day}–{end.day} {end.strftime('%b')}"
    return f"{_short_date(start)} – {_short_date(end)}"


def _date(value: Any) -> date | None:
    if not isinstance(value, str) or len(value) < 10:
        return None
    try:
        return date.fromisoformat(value[:10])
    except ValueError:
        return None


# --- attachments -------------------------------------------------------------

_IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".bmp"}


def attachment_id(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()[:24]


def _host_allowed(host: str, allowed: str) -> bool:
    allowed = allowed.strip().lower()
    if not allowed:
        return False
    if allowed.startswith("."):
        return host.endswith(allowed) or host == allowed[1:]
    return host == allowed


def file_url_allowed(url: str | None) -> bool:
    """Only https URLs on Aula's own hosts are ever fetched by the server.

    Aula hands out file URLs on ``*.aula.dk``; the library and the portal
    bundle name no other file host. ``SALA_EXTRA_FILE_HOSTS`` (comma list,
    ``.example.com`` = that domain and its subdomains) can add one without a
    code change if real files turn out to live elsewhere (e.g. an S3 bucket).
    """
    if not url:
        return False
    try:
        parts = urlsplit(url)
    except ValueError:
        return False
    host = (parts.hostname or "").lower()
    if parts.scheme != "https" or not host:
        return False
    allowed = [".aula.dk", *os.environ.get("SALA_EXTRA_FILE_HOSTS", "").split(",")]
    return any(_host_allowed(host, a) for a in allowed)


def _is_web_link(url: str | None) -> bool:
    return bool(url) and urlsplit(url).scheme in ("http", "https")


def map_attachments(attachments: list[Attachment], register: Register) -> list[dict]:
    out = []
    for att in attachments:
        if att.file is None:
            # A cloud-drive link (or a secure document, which has no URL): the
            # app opens links in the browser; the server never fetches them.
            link = att.link.url if att.link else None
            if _is_web_link(link):
                out.append({"id": None, "name": att.name or link, "kind": "link", "url": link})
            continue
        url = att.file.url
        if not file_url_allowed(url):
            if url:
                _LOGGER.warning("Skipping attachment on a non-Aula host: %s", urlsplit(url).hostname)
            continue
        name = att.name or att.file.name or "attachment"
        media_type = (att.media.media_type if att.media else "").lower()
        ext = "." + name.rsplit(".", 1)[-1].lower() if "." in name else ""
        mime = mimetypes.guess_type(name)[0] or ""
        is_image = media_type in ("image", "media") or ext in _IMAGE_EXT or mime.startswith("image/")
        out.append({"id": register(url, name), "name": name, "kind": "image" if is_image else "file"})
    return out


async def download_attachment(client: AulaApiClient, url: str, max_redirects: int = 5, *, fake: bool = False) -> bytes:
    """Fetch a registered Aula file, following redirects only onto allowed hosts.

    The library's httpx client follows every redirect, so with a real client
    we go to its inner ``httpx.AsyncClient`` (same cookies) with
    ``follow_redirects=False`` and check each hop. The fake has no inner
    client and serves fixture bytes; outside fake mode a missing inner client
    is an error, never an unchecked download.
    """
    if not file_url_allowed(url):
        raise UpstreamFailure("attachment is not on an Aula file host")
    inner = getattr(client._client, "_client", None)
    if not isinstance(inner, httpx.AsyncClient):
        if fake:
            return await client.download_file(url)
        _LOGGER.error("Aula client has no inner httpx client; refusing an unchecked download")
        raise UpstreamFailure("attachment download is not available")
    for _ in range(max_redirects + 1):
        resp = await inner.get(url, follow_redirects=False, timeout=httpx.Timeout(30.0, read=120.0))
        if resp.is_redirect:
            url = str(resp.url.join(resp.headers.get("location", "")))
            if not file_url_allowed(url):
                _LOGGER.warning("Attachment redirected off Aula to %s", urlsplit(url).hostname)
                raise UpstreamFailure("attachment redirected to a non-Aula host")
            continue
        resp.raise_for_status()
        return resp.content
    raise UpstreamFailure("too many redirects downloading the attachment")


# --- children ----------------------------------------------------------------

_STATUS = {
    PresenceState.PRESENT: "present",
    PresenceState.FIELDTRIP: "present",
    PresenceState.SLEEPING: "present",
    PresenceState.SPARE_TIME_ACTIVITY: "present",
    PresenceState.PHYSICAL_PLACEMENT: "present",
    PresenceState.NOT_PRESENT: "not_arrived",
    PresenceState.NOT_ARRIVED: "not_arrived",
    PresenceState.SICK: "sick",
    PresenceState.CHECKED_OUT: "gone_home",
    PresenceState.REPORTED_ABSENT: "vacation",
}


@dataclass
class ChildDay:
    """Everything known about one child today, fetched once."""

    child: Child
    overview: Any = None  # DailyOverview | None
    template: Any = None  # DayTemplate | None (today's, effective)
    config: Any = None  # PresenceConfiguration | None
    opens_at: str | None = None
    closes_at: str | None = None
    people: list[str] | None = None


async def _optional[T](label: str, coro) -> T | None:
    """Await a read whose failure should not fail the whole response.

    A dead session still propagates so the session manager can react; a 403
    or step-up on one source (e.g. a guessed endpoint) is just a missing part.
    """
    try:
        return await coro
    except Exception as e:  # noqa: BLE001 - one source failing must not break /today
        if session_gone(e):
            raise
        _LOGGER.warning("%s failed: %s", label, e)
        return None


async def _today_template(client: AulaApiClient, child_id: int, today: date):
    templates = await client.get_presence_templates([child_id], today, today)
    for week in templates:
        if week.institution_profile and week.institution_profile.id == child_id:
            for day in week.day_templates:
                if day.by_date and day.by_date[:10] == today.isoformat():
                    return day
    return None


async def opening_hours(client: AulaApiClient, institution_code: str, day: date) -> tuple[str | None, str | None]:
    """Opening/closing time for ``day``, or (None, None).

    The library has no method for this. Endpoint and response shape come from
    the portal bundle (app.*.js, LOAD_PRESENCE_OPEN_HOURS_GUARDIAN_DASHBOARD:
    ``?method=presence.getOpeningHoursByInstitutionCodes`` with params
    institutionCodes/startDate/endDate; components read
    ``data.openingHoursOverviewDto[].openingHoursDto[]`` with
    date/type/openTime/closeTime, type one of specific_opening_hours,
    general_opening_hours, closed_day, default_opening_hours). Axios sends
    array params as ``institutionCodes[]``.
    """
    resp = await client._request_with_version_retry(
        "get",
        client.api_url,
        params={
            "method": "presence.getOpeningHoursByInstitutionCodes",
            "institutionCodes[]": [institution_code],
            "startDate": day.isoformat(),
            "endDate": day.isoformat(),
        },
    )
    resp.raise_for_status()
    for overview in get_in(resp.json(), "data.openingHoursOverviewDto", default=[]) or []:
        if not isinstance(overview, dict) or overview.get("institutionCode") != institution_code:
            continue
        for entry in overview.get("openingHoursDto") or []:
            if isinstance(entry, dict) and str(entry.get("date", ""))[:10] == day.isoformat():
                if entry.get("type") == "closed_day":
                    return None, None
                return hhmm(entry.get("openTime")), hhmm(entry.get("closeTime"))
    return None, None


def person_label(person) -> str:
    """'Name (Relation)', the format Aula wants in exitWith (see cli._strip_relation)."""
    return f"{person.name} ({person.relation})" if person.relation else person.name


async def pickup_people(client: AulaApiClient, child_id: int) -> list[str]:
    people: list[str] = []
    for responsibles in await client.get_pickup_responsibles([child_id]):
        if responsibles.uni_student_id not in (0, child_id):
            continue
        for person in responsibles.persons:
            label = person_label(person)
            if label and label not in people:
                people.append(label)
    return people


async def load_child_day(client: AulaApiClient, child: Child, *, with_people: bool = False) -> ChildDay:
    today = aula_today()

    async def hours():
        if not child.institution_code:
            return None
        return await opening_hours(client, child.institution_code, today)

    async def config():
        configs = await client.get_presence_configuration([child.id])
        return next((c for c in configs if c.child_id in (None, child.id)), None)

    async def none():
        return None

    overview, template, cfg, oh, people = await asyncio.gather(
        _optional("daily overview", client.get_daily_overview(child.id)),
        _optional("presence template", _today_template(client, child.id, today)),
        _optional("presence configuration", config()),
        _optional("opening hours", hours()),
        _optional("pickup responsibles", pickup_people(client, child.id)) if with_people else none(),
    )
    day = ChildDay(child=child, overview=overview, template=template, config=cfg, people=people)
    if oh:
        day.opens_at, day.closes_at = oh
    return day


def _current_pickup(day: ChildDay) -> tuple[str | None, str | None, str]:
    t, ov = day.template, day.overview
    when = hhmm((t.exit_time if t else None) or (ov.exit_time if ov else None))
    who = (t.exit_with if t else None) or (ov.exit_with if ov else None) or None
    note = (t.comment if t else None) or (ov.comment if ov else None) or ""
    return when, who, note


def child_out(day: ChildDay) -> dict:
    ov = day.overview
    state = ov.status if ov else None
    when, who, _ = _current_pickup(day)
    institution = day.child.institution_name or (
        ov.institution_profile.institution_name if ov and ov.institution_profile else None
    )
    group = (ov.main_group.name if ov and ov.main_group else None) or get_in(
        day.child._raw or {}, "institutionProfile.metadata"
    )
    return {
        "id": day.child.id,
        "name": day.child.name or "",
        "institution": institution or "",
        "group": group or "",
        "status": _STATUS.get(state, "unknown") if state else "unknown",
        "statusLabel": state.display_name if state else "Unknown",
        "arrivedAt": hhmm(ov.check_in_time) if ov else None,
        "leftAt": hhmm(ov.check_out_time) if ov else None,
        "pickup": {"time": when, "by": who},
        "closesAt": day.closes_at,
        "canReportSick": bool(day.config and day.config.can_edit(PresenceModule.REPORT_SICK)),
    }


def pickup_times(current: str | None, opens_at: str | None, closes_at: str | None, at: datetime) -> list[str]:
    """30-minute grid from now (or 3 h before closing) to closing, plus the
    current pickup time and closing time, as in API.md's own example."""
    close = time.fromisoformat(closes_at) if closes_at else time(17, 0)
    close_m = close.hour * 60 + close.minute
    now_m = at.hour * 60 + at.minute
    start_m = max(now_m, close_m - 180)
    if opens_at:
        o = time.fromisoformat(opens_at)
        start_m = max(start_m, o.hour * 60 + o.minute)
    first = -(-start_m // 30) * 30  # round up to the half hour
    slots = {m for m in range(first, close_m + 1, 30)}
    if now_m <= close_m:
        slots.add(close_m)
    out = {f"{m // 60:02d}:{m % 60:02d}" for m in slots}
    if current:
        out.add(current)
    return sorted(out)


def pickup_out(day: ChildDay) -> dict:
    when, who, note = _current_pickup(day)
    return {
        "date": aula_today().isoformat(),
        "opensAt": day.opens_at,
        "closesAt": day.closes_at,
        "times": pickup_times(when, day.opens_at, day.closes_at, now()),
        "people": day.people or [],
        "current": {"time": when, "by": who},
        "note": note,
    }


async def set_pickup(client: AulaApiClient, child: Child, when: str, by: str, note: str | None) -> None:
    """Change today's pickup only, the way the portal's guardian dashboard does.

    Today's existing day template supplies the entry time and (unless the app
    sent a note) the comment. If that template repeats (weekly etc.) it is
    left alone: we write a single-day template for today with no id and
    repeatPattern "never". So does a template whose repeatPattern is missing.
    That matches the portal's "edit today" drawer
    (app.*.js ``updateTemplate``: posts {institutionProfileId, byDate,
    presenceActivity, comment} and never an id; the week editor doesn't send an
    id either). Only a template that is already a one-off for today is updated
    by id, as ``aula update-presence`` does (cli.py ~3770). A day the child
    is registered absent (vacation) is refused (-> 409) rather than overwritten.
    """
    today = aula_today()
    # These reads decide what gets written, so a failure stops the write
    # (-> 502) instead of posting a blank entry time / comment over real ones.
    try:
        people = await pickup_people(client, child.id)
        t = await _today_template(client, child.id, today)
    except Exception as e:
        if session_gone(e):
            raise
        raise UpstreamFailure(f"Could not read today's pickup before changing it: {e}") from e
    if by not in people:
        raise BadRequest("by must be one of people")
    if t and t.is_on_vacation:
        raise Conflict(f"{child.name} is registered absent today")
    ov = await _optional("daily overview", client.get_daily_overview(child.id))
    # No invented default: the portal sends entryTime null when drop-off time
    # isn't set (preparePresenceTemplateParams), so we pass None through.
    entry = hhmm((t.entry_time if t else None) or (ov.entry_time if ov else None))
    if note is None:
        note = (t.comment if t else None) or (ov.comment if ov else None) or ""
    # Only an explicit one-off ("never") is updated in place; a missing or
    # unknown repeatPattern may be a series, so it gets a new day override.
    one_off = bool(t and (t.repeat_pattern or "").lower() == "never")
    template_id = t.id if one_off and (t.by_date or "")[:10] == today.isoformat() else None
    await client.update_presence_template(
        child.id,
        today,
        entry_time=entry,  # type: ignore[arg-type] - None is sent as JSON null, like the portal
        exit_time=when,
        activity_type=ActivityType.PICKED_UP_BY,
        exit_with=by,
        comment=note,
        template_id=template_id,
        repeat_pattern="Never",
    )


async def set_sick(client: AulaApiClient, child: Child, sick: bool) -> None:
    """Report sick, or take it back. Undo restores PRESENT when the child was
    checked in today and not yet checked out, otherwise NOT_PRESENT."""
    if sick:
        status = PresenceState.SICK
    else:
        try:
            ov = await client.get_daily_overview(child.id)
        except Exception as e:
            if session_gone(e):
                raise
            raise UpstreamFailure(f"Could not read today's presence before undoing sick: {e}") from e
        checked_in = bool(ov and ov.check_in_time and not ov.check_out_time)
        status = PresenceState.PRESENT if checked_in else PresenceState.NOT_PRESENT
    if not await client.update_presence_status([child.id], status):
        raise UpstreamFailure("Aula did not accept the status change")


# --- attention / upcoming ----------------------------------------------------


async def holiday_requests(client: AulaApiClient, child_ids: list[int]) -> list[dict]:
    today = aula_today()
    out = []
    for reg in await client.get_vacation_registrations(child_ids):
        if not reg.is_missing_answer:
            continue
        start, end = _date(reg.start_date), _date(reg.end_date)
        deadline = _date(reg.response_deadline)
        title = f"Holiday request: {date_range_label(start, end) if start else reg.title or 'no dates'}"
        out.append(
            {
                "id": f"vacation-{reg.id}",
                "kind": "holiday_request",
                "title": title,
                "subtitle": f"Answer by {_short_date(deadline)}" if deadline else None,
                "urgent": bool(deadline and (deadline - today).days <= 2),
                "threadId": None,
                "_sort": deadline or date.max,
            }
        )
    out.sort(key=lambda a: a.pop("_sort"))
    return out


def unread_threads_attention(threads: list[dict], limit: int = 3) -> list[dict]:
    out = []
    for t in threads:
        if t["unread"]:
            out.append(
                {
                    "id": f"thread-{t['id']}",
                    "kind": "message",
                    "title": t["subject"],
                    "subtitle": t["from"],
                    "urgent": False,
                    "threadId": t["id"],
                }
            )
        if len(out) >= limit:
            break
    return out


async def upcoming(client: AulaApiClient, children: list[Child], groups: list[str], limit: int = 5) -> list[dict]:
    today = aula_today()
    horizon = today + timedelta(days=30)
    items: list[dict] = []

    events = await _optional("important dates", client.get_important_dates(limit=10, include_today=True)) or []
    for ev in events:
        if not isinstance(ev, dict):
            continue
        d = _date(iso(ev.get("startDateTime")) or ev.get("startDateTime") or ev.get("startDate"))
        if d and today <= d <= horizon and ev.get("title"):
            items.append({"date": d.isoformat(), "title": ev["title"], "subtitle": None})

    # Birthday rows: shape is a guess (name / birthday / mainGroupName); the
    # library returns them untyped and the bundle doesn't show the fields.
    codes = sorted({c.institution_code for c in children if c.institution_code})
    if codes:
        start = datetime.combine(today, time.min, TZ).isoformat()
        end = datetime.combine(horizon, time.max, TZ).isoformat()
        rows = await _optional("birthdays", client.get_birthday_events(codes, start, end)) or []
        for row in rows:
            if not isinstance(row, dict):
                continue
            born = _date(row.get("birthday") or row.get("birthDate") or row.get("startDateTime"))
            name = row.get("name") or row.get("fullName")
            if not born or not name:
                continue
            try:
                d = born.replace(year=today.year)
            except ValueError:  # 29 Feb
                d = date(today.year, 3, 1)
            if d < today:
                d = d.replace(year=today.year + 1)
            if d <= horizon:
                group = row.get("mainGroupName") or row.get("groupName")
                items.append({"date": d.isoformat(), "title": f"{name}'s birthday", "subtitle": group})

    items.sort(key=lambda i: i["date"])
    return items[:limit]


# --- posts -------------------------------------------------------------------


def post_out(post, register: Register) -> dict:
    owner = post.owner
    author = " · ".join(p for p in (owner.full_name or owner.role, owner.institution_name) if p)
    return {
        "id": post.id,
        "title": post.title or "",
        "author": author,
        "date": iso(post.timestamp),
        "body": plain(post.content_html),
        "important": bool(post.is_important),
        # posts.getAllPosts rows carry isBookmarked (bundle 10.*.js reads post.isBookmarked).
        "saved": bool((post._raw or {}).get("isBookmarked")),
        "attachments": map_attachments(post.attachments, register),
    }


async def posts(client: AulaApiClient, profile: Profile, register: Register, limit: int = 10) -> list[dict]:
    # A post without a timestamp has no valid "date" for the app; skip it.
    rows = await client.get_posts(profile.institution_profile_ids, limit=limit)
    return [post_out(p, register) for p in rows if p.timestamp is not None]


async def set_bookmark(client: AulaApiClient, post_id: int, saved: bool) -> None:
    # Endpoints from the portal bundle (10.*.js): POST ?method=posts.bookmark /
    # posts.unbookmark with body {postId}. Not in the library.
    method = "posts.bookmark" if saved else "posts.unbookmark"
    resp = await client._request_with_version_retry(
        "post", f"{client.api_url}?method={method}", json={"postId": post_id}
    )
    resp.raise_for_status()


# --- messages ----------------------------------------------------------------

_SHOWN_TYPES = {"Message", "MessageEdited", "AutoReply", "Forward"}


def _sender_name(sender: Any) -> str | None:
    return get_in(sender, "fullName") or get_in(sender, "answerDirectlyName") or None


def thread_out(raw: dict) -> dict:
    """One row of messaging.getThreads. Field names (read, muted, marked,
    recipients[].leaveTime, latestMessage.text.html / sendDateTime, creator)
    are the ones the portal reads; latestMessage.sender is a guess with
    creator as fallback."""
    latest = raw.get("latestMessage") or {}
    recipients = [r for r in raw.get("recipients") or [] if isinstance(r, dict) and r.get("leaveTime") is None]
    preview = plain(get_in(latest, "text.html", default="") or "")
    preview = " ".join(preview.split())
    if len(preview) > 140:
        preview = preview[:139].rstrip() + "…"
    return {
        "id": str(raw.get("id")),
        "subject": raw.get("subject") or "",
        "from": _sender_name(latest.get("sender")) or _sender_name(raw.get("creator")) or "",
        "participants": len(recipients) or len(raw.get("participants") or []),
        "preview": preview,
        "date": iso(latest.get("sendDateTime") or raw.get("lastUpdatedDate")),
        "unread": not raw.get("read", True),
        "muted": bool(raw.get("muted")),
        "starred": bool(raw.get("marked")),
    }


async def threads(client: AulaApiClient) -> list[dict]:
    # "date" is non-nullable in API.md; a row without any timestamp is skipped.
    rows = [thread_out(t._raw or {}) for t in await client.get_message_threads()]
    return [r for r in rows if r["date"]]


def _from_me(message: dict, mine: set[int]) -> bool:
    # Portal (app.*.js senderIsSelf): sender.mailBoxOwner.id is one of the
    # user's institution profile ids.
    return get_in(message, "sender.mailBoxOwner.id") in mine


async def _thread_meta(client: AulaApiClient, thread_id: str) -> dict:
    resp = await client._request_with_version_retry(
        "get", f"{client.api_url}?method=messaging.getMessagesForThread&threadId={thread_id}&page=0&limit=20"
    )
    resp.raise_for_status()
    data = resp.json().get("data")
    if not isinstance(data, dict):
        raise NotFound(f"thread {thread_id}")
    return data


async def thread_detail(client: AulaApiClient, profile: Profile, thread_id: str, register: Register) -> dict:
    meta = await _thread_meta(client, thread_id)
    raw_messages = await client.get_all_messages_for_thread(thread_id)
    mine = guardian_profile_ids(profile)
    shown = [
        m for m in raw_messages
        if isinstance(m, dict) and m.get("messageType") in _SHOWN_TYPES and iso(m.get("sendDateTime"))
    ]
    newest = shown[0]["id"] if shown else None
    messages = [
        {
            "id": str(m.get("id")),
            "sender": _sender_name(m.get("sender")) or "",
            "fromMe": _from_me(m, mine),
            "date": iso(m.get("sendDateTime")),
            "text": plain(get_in(m, "text.html", default="") or (m.get("text") if isinstance(m.get("text"), str) else "")),
            "attachments": map_attachments(parse_attachments(m.get("attachments")), register),
        }
        for m in reversed(shown)  # Aula sends newest first; the app gets oldest first
    ]
    if newest and meta.get("lastReadMessageId") != newest:
        await _optional("mark thread read", client.mark_thread_read(thread_id))
    return {
        "id": str(thread_id),
        "subject": meta.get("subject") or "",
        "canReply": not meta.get("isArchived") and meta.get("leaveTime") is None,
        "messages": messages,
    }


def _int_or_str(value: str) -> int | str:
    return int(value) if str(value).isdigit() else value


async def reply_all(client: AulaApiClient, thread_id: str, text: str) -> str:
    # Body from the portal bundle (0.*.js REPLY_MESSAGE):
    # {threadId, message:{text, attachmentIds}, commonInboxId, otpInboxId}.
    resp = await client._request_with_version_retry(
        "post",
        f"{client.api_url}?method=messaging.reply",
        json={
            "threadId": _int_or_str(thread_id),
            "message": {"text": text_to_html(text), "attachmentIds": []},
            "commonInboxId": None,
            "otpInboxId": None,
        },
    )
    resp.raise_for_status()
    return str(thread_id)


def _recipient_from_sender(sender: dict) -> dict:
    """Portal's mapInstitutionProfileToRecipient(message.sender) + the
    NewMessage recipient class (app.*.js): id is the sender's mailbox owner id
    (forwardMessage overwrites sender.id with sender.mailBoxOwner.id), and an
    OTP/common inbox sender turns the type into that inbox."""
    owner = sender.get("mailBoxOwner") or {}
    owner_type = owner.get("mailBoxOwnerType")
    owner_id = owner.get("id") or sender.get("id")
    otp = owner_id if owner_type == "otpInbox" else None
    common = owner_id if owner_type == "commonInbox" else None
    return {
        "id": owner_id,
        "profileId": sender.get("profileId"),
        "mailBoxOwnerType": "otpInbox" if otp else "commonInbox" if common else "institutionProfile",
        "otpInboxId": otp,
        "commonInboxId": common,
        "name": sender.get("fullName"),
        "fullName": sender.get("fullName"),
        "metadata": sender.get("metadata"),
        "label": f"{sender.get('fullName')} ({sender.get('metadata')})" if sender.get("metadata") else sender.get("fullName"),
        "institutionCode": sender.get("institutionCode"),
        "type": "profile",
        "portalRole": sender.get("role"),
    }


def _new_thread_id(data: Any) -> str | None:
    """startNewThread's answer. The portal opens ``response.data.data.data``
    (handleSendMessageResponse), i.e. body.data.data; unverified live, so
    accept a bare id or an object with data/id/threadId."""
    if isinstance(data, bool):
        return None
    if isinstance(data, (int, str)) and str(data):
        return str(data)
    if isinstance(data, dict):
        for key in ("data", "threadId", "id", "subscriptionId"):
            found = _new_thread_id(data.get(key))
            if found:
                return found
    return None


async def reply_sender(client: AulaApiClient, profile: Profile, thread_id: str, message_id: str, text: str) -> str | None:
    """Aula's "Svar afsender direkte" (ANSWER_DIRECTLY): a new thread to the
    sender of one message only, via messaging.startNewThread.

    Shape from the portal bundle (app.*.js / 0.*.js):
    - START_NEW_THREAD body: {subject, recipients, bccRecipients, sensitive,
      creator:{id, mailBoxOwnerType}, message:{text, attachmentIds}, forwardInfo}
    - a guardian's creator is their institution profile for the thread's
      institution, with mailBoxOwnerType "institutionProfile"
    - subject "Vs. " + subject and sensitivity from messaging.getMessageInfoLight
      (populateRelatedMessageInfo)
    - forwardInfo for ANSWER_DIRECTLY: {forwardedThreadId, forwardedMessageIds:[id], directReply:true}
    """
    mine = guardian_profile_ids(profile)
    raw_messages = await client.get_all_messages_for_thread(thread_id)
    message = next((m for m in raw_messages if isinstance(m, dict) and str(m.get("id")) == str(message_id)), None)
    if message is None:
        raise NotFound(f"message {message_id}")
    if _from_me(message, mine):
        raise BadRequest("messageId is one of your own messages")
    if message.get("canReplyToMessage") is False:
        raise BadRequest("Aula does not allow a direct reply to this message")

    info = await _optional("message info", client.get_message_info(thread_id, message_id)) or {}
    meta = await _thread_meta(client, thread_id)
    subject = info.get("subject") or meta.get("subject")
    if not subject:
        rows = await _optional("threads", client.get_message_threads()) or []
        subject = next(((r._raw or {}).get("subject") for r in rows if str(r.thread_id) == str(thread_id)), None)
    if not subject:
        raise UpstreamFailure("could not read the thread subject for a direct reply")
    sender = get_in(info, "message.sender") or message.get("sender") or {}
    owner = meta.get("mailBoxOwner") or {}
    creator_id = owner.get("id") if owner.get("mailBoxOwnerType") == "institutionProfile" else None
    if creator_id is None:
        creator_id = next(iter(sorted(mine)), None)
    if creator_id is None or not get_in(sender, "mailBoxOwner.id"):
        raise UpstreamFailure("could not work out sender or recipient for a direct reply")

    resp = await client._request_with_version_retry(
        "post",
        f"{client.api_url}?method=messaging.startNewThread",
        json={
            "subject": f"Vs. {subject}",
            "recipients": [_recipient_from_sender(sender)],
            "bccRecipients": [],
            "sensitive": bool(info.get("isSensitive", meta.get("sensitive", False))),
            "creator": {"id": creator_id, "mailBoxOwnerType": "institutionProfile"},
            "message": {"text": text_to_html(text), "attachmentIds": []},
            "forwardInfo": {
                "forwardedThreadId": _int_or_str(thread_id),
                "forwardedMessageIds": [message.get("id")],
                "directReply": True,
            },
        },
    )
    resp.raise_for_status()
    return _new_thread_id(resp.json().get("data"))
