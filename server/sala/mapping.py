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
from aula.api_client import validate_vacation
from aula.http import AulaAuthenticationError, AulaInvalidTokenError, AulaSessionExpiredError, HttpRequestError
from aula.models import ActivityType, Child, PresenceModule, PresenceModulePermission, PresenceState, Profile
from aula.models.attachment import Attachment, parse_attachments
from aula.utils.dates import aula_today, parse_api_datetime
from aula.utils.html import html_to_plain
from aula.utils.mapping import get_in

_LOGGER = logging.getLogger(__name__)
TZ = ZoneInfo("Europe/Copenhagen")

# Register an attachment URL server-side: (url, name, key=None) -> the opaque id to hand out.
Register = Callable[..., str]


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


def valid_hhmm(value: Any) -> bool:
    """Exactly "HH:mm" (fromisoformat alone accepts "24:00" and other ISO forms)."""
    try:
        return isinstance(value, str) and len(value) == 5 and time.fromisoformat(value).strftime("%H:%M") == value
    except ValueError:
        return False


def local_date(value: Any) -> date | None:
    """A date or timestamp from Aula -> the date in Copenhagen ("2026-12-20T23:00:00Z" is 21 Dec)."""
    return _date(iso(value) or value)


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


def picture_id(picture: Any, register: Register | None) -> str | None:
    """A person's ``profilePicture`` (Aula's dict with ``url``, or the URL itself) as an attachment id.

    Picture URLs may be signed, so the id hashes the URL without its query:
    it stays the same across loads (the app caches by it) while the stored URL
    is refreshed each time."""
    url = get_in(picture, "url") if isinstance(picture, dict) else picture
    if register is None or not url:
        return None
    if not file_url_allowed(url):
        _LOGGER.warning("Skipping profile picture on a non-Aula host: %s", urlsplit(url).hostname)
        return None
    parts = urlsplit(url)
    return register(url, parts.path.rsplit("/", 1)[-1] or "picture", parts._replace(query="", fragment="").geturl())


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
    for entry in await _opening_hours_rows(client, institution_code, day, day):
        if str(entry.get("date", ""))[:10] == day.isoformat():
            if entry.get("type") == "closed_day":
                return None, None
            return hhmm(entry.get("openTime")), hhmm(entry.get("closeTime"))
    return None, None


async def _opening_hours_rows(client: AulaApiClient, institution_code: str, start: date, end: date) -> list[dict]:
    resp = await client._request_with_version_retry(
        "get",
        client.api_url,
        params={
            "method": "presence.getOpeningHoursByInstitutionCodes",
            "institutionCodes[]": [institution_code],
            "startDate": start.isoformat(),
            "endDate": end.isoformat(),
        },
    )
    resp.raise_for_status()
    rows = []
    for overview in get_in(resp.json(), "data.openingHoursOverviewDto", default=[]) or []:
        if isinstance(overview, dict) and overview.get("institutionCode") == institution_code:
            rows += [e for e in overview.get("openingHoursDto") or [] if isinstance(e, dict)]
    return rows


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


def child_out(day: ChildDay, register: Register) -> dict:
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
        # The overview is fetched fresh; the profile (and its signed URL) is cached for the whole session.
        "picture": picture_id(
            (ov.institution_profile.profile_picture.url if ov and ov.institution_profile and ov.institution_profile.profile_picture else None)
            or day.child.profile_picture,
            register,
        ),
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
    ids: set[int] = set()
    for reg in await client.get_vacation_registrations(child_ids):
        if not reg.is_missing_answer or reg.id in ids:  # one row per child; one card per request
            continue
        ids.add(reg.id)
        start, end = local_date(reg.start_date), local_date(reg.end_date)
        deadline = local_date(reg.response_deadline)
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


# --- holidays ----------------------------------------------------------------


def _weekdays(start: date, end: date) -> list[date]:
    return [start + timedelta(days=i) for i in range((end - start).days + 1) if (start + timedelta(days=i)).isoweekday() <= 5]


async def _vacation_response(client: AulaApiClient, response_id: int) -> dict:
    """One child's answer to a holiday request.

    Endpoint from the portal bundle (0.*.js LOAD_VACATION_REQUEST_RESPONSE:
    GET ``?method=presence.getVacationRegistrationResponse`` with param
    ``vacationRegistrationResponseId``, the request row's ``responseId``).
    The drawer (10.*.js) reads ``data.vacationRegistrationResponse`` with
    vacationRegistrationResponseId, childId, comment and
    days[]{date, isComing, entryTime, exitTime}. Not in the library.
    """
    resp = await client._request_with_version_retry(
        "get",
        client.api_url,
        params={"method": "presence.getVacationRegistrationResponse", "vacationRegistrationResponseId": response_id},
    )
    resp.raise_for_status()
    data = get_in(resp.json(), "data.vacationRegistrationResponse")
    if not isinstance(data, dict):
        raise UpstreamFailure("Aula sent no answer for the holiday request")
    return data


async def _closed_days(client: AulaApiClient, institution_code: str, start: date, end: date) -> set[date]:
    rows = await _opening_hours_rows(client, institution_code, start, end)
    return {d for r in rows if r.get("type") == "closed_day" and (d := _date(r.get("date")))}


async def _holiday(client: AulaApiClient, profile: Profile, request_id: str, *, strict: bool) -> tuple[dict, dict[int, dict]]:
    """``GET /holiday-requests/{id}``, plus each child's raw Aula answer by child id.

    Title, note, deadline and dates come from the request rows the library
    parses (``presence.getVacationRegistrationsByChildren``, one row per
    child); the answer read gives only the days, the comment and the ids.
    Days follow the portal drawer (10.*.js populateVacationRequestDaysList /
    updateDisabled): Mon–Fri from startDate to endDate; a day is disabled
    when it is today or earlier, a closed day, or the deadline has passed.
    ``strict`` (before a write) fails on any read; otherwise the answer and
    closed-day reads are optional.
    """
    reg_id = request_id.removeprefix("vacation-")
    if not request_id.startswith("vacation-") or not reg_id.isdigit():
        raise NotFound(f"holiday request {request_id}")
    regs = [r for r in await client.get_vacation_registrations([c.id for c in profile.children]) if r.id == int(reg_id)]
    if not regs:
        raise NotFound(f"holiday request {request_id}")
    today = aula_today()
    first = regs[0]
    start, end = local_date(first.start_date), local_date(first.end_date)
    deadline = local_date(first.response_deadline)
    open_ = deadline is None or today <= deadline

    async def read[T](label: str, coro) -> T | None:
        return await coro if strict else await _optional(label, coro)

    children, responses = [], {}
    for reg in regs:
        child = next((c for c in profile.children if c.id == reg.child_id), None)
        response = (await read("holiday answer", _vacation_response(client, reg.response_id)) if reg.response_id else None) or {}
        responses[reg.child_id] = response
        answers = {}
        for d in response.get("days") or []:
            day = local_date(d.get("date")) if isinstance(d, dict) else None
            if day:
                answers[day] = d
        code = child.institution_code if child else None
        closed = (await read("opening hours", _closed_days(client, code, start, end)) if code and start and end else None) or set()
        may_answer = open_ and (child is None or child.has_custody_or_extended_access is not False)
        days = []
        for day in _weekdays(start, end) if start and end else []:
            a = answers.get(day, {})
            coming = a.get("isComing")
            days.append(
                {
                    "date": day.isoformat(),
                    "coming": coming if isinstance(coming, bool) else None,
                    "entryTime": hhmm(a.get("entryTime")),
                    "exitTime": hhmm(a.get("exitTime")),
                    "editable": may_answer and day > today and day not in closed,
                }
            )
        children.append(
            {
                "id": reg.child_id,
                "name": (child.name if child else None) or reg.child_name or "",
                "answered": not reg.is_missing_answer,
                "comment": response.get("comment") or "",
                "days": days,
            }
        )
    out = {
        "id": f"vacation-{first.id}",
        "title": first.title or "",
        "note": first.note_to_guardian or None,
        "deadline": deadline.isoformat() if deadline else None,
        "startDate": start.isoformat() if start else None,
        "endDate": end.isoformat() if end else None,
        "timesRequired": bool(first.is_presence_times_required),
        "answered": all(c["answered"] for c in children),
        "editable": open_,
        "children": children,
    }
    return out, responses


async def holiday_request(client: AulaApiClient, profile: Profile, request_id: str) -> dict:
    return (await _holiday(client, profile, request_id, strict=False))[0]


@dataclass
class DayAnswer:
    date: str
    coming: bool
    entry_time: str | None = None
    exit_time: str | None = None


@dataclass
class ChildAnswer:
    days: list[DayAnswer]
    comment: str = ""


async def answer_holiday_request(
    client: AulaApiClient, profile: Profile, request_id: str, answers: dict[int, ChildAnswer]
) -> None:
    """Answer a holiday request for one or more children, one Aula write per child.

    Payload from the portal bundle (10.*.js, the guardian's vacation response
    drawer, ``updateVacationResponses`` -> ``ADD_VACATION`` action in 0.*.js,
    which POSTs it to ``?method=calendar.respondToVacationRegistrationRequest``):
    ``{vacationRegistrationResponseId, childId, days:[{date, isComing,
    entryTime, exitTime}], comment}``, both ids from the answer read
    (``vacationRegistrationResponse``). ``days`` holds only the enabled days
    (``filter(!isDisabled)``), dates as "YYYY-MM-DD"; times are "" unless the
    child comes and the request has ``isPresenceTimesRequired`` ("HH:mm" from
    the time picker). Every enabled day must have an answer (validateIsComing).
    Never tried against live Aula.
    """
    if not answers:
        raise BadRequest("children is empty")
    out, responses = await _holiday(client, profile, request_id, strict=True)
    if not out["editable"]:
        raise Conflict("The deadline for this holiday request has passed")
    by_child = {c["id"]: c for c in out["children"]}
    payloads = []
    for child_id, answer in answers.items():
        child = by_child.get(child_id)
        if child is None:
            raise BadRequest(f"child {child_id} is not part of this holiday request")
        known = {d["date"]: d for d in child["days"]}
        given: dict[str, DayAnswer] = {}
        for a in answer.days:
            if a.date not in known:
                raise BadRequest(f"{a.date} is not a day of this holiday request")
            if not known[a.date]["editable"]:
                raise BadRequest(f"{a.date} can no longer be answered")
            if a.date in given:
                raise BadRequest(f"{a.date} is answered twice")
            for t in (a.entry_time, a.exit_time):
                if t is not None and not valid_hhmm(t):
                    raise BadRequest(f"{a.date}: times must be HH:mm")
            if a.coming and out["timesRequired"]:
                if not (a.entry_time and a.exit_time):
                    raise BadRequest(f"{a.date}: entryTime and exitTime are required")
                if a.entry_time >= a.exit_time:
                    raise BadRequest(f"{a.date}: entryTime must be before exitTime")
            given[a.date] = a
        missing = sorted(d for d, info in known.items() if info["editable"] and d not in given)
        if missing:
            raise BadRequest(f"{child['name'] or child_id}: no answer for {missing[0]}")
        if not given:
            raise Conflict(f"{child['name'] or child_id} has no days left to answer")
        response = responses.get(child_id) or {}
        response_id = response.get("vacationRegistrationResponseId")
        if not response_id:
            raise UpstreamFailure(f"Aula gave no answer id for {child['name'] or child_id}")
        with_times = out["timesRequired"]
        payloads.append(
            {
                "vacationRegistrationResponseId": response_id,
                "childId": response.get("childId") or child_id,
                "days": [
                    {
                        "date": d,
                        "isComing": a.coming,
                        "entryTime": a.entry_time if a.coming and with_times else "",
                        "exitTime": a.exit_time if a.coming and with_times else "",
                    }
                    for d, a in sorted(given.items())
                ],
                "comment": answer.comment,  # per child: each answer has its own comment in Aula
            }
        )
    for payload in payloads:
        resp = await client._request_with_version_retry(
            "post", f"{client.api_url}?method=calendar.respondToVacationRegistrationRequest", json=payload
        )
        resp.raise_for_status()


async def _vacation_denials(client: AulaApiClient, children: list[Child]) -> dict[int, str]:
    """Children Aula is known to refuse an absence for, with the reason.

    Copied from the library CLI's ``_vacation_denials`` (aula/cli.py): no
    custody, or the presence configuration doesn't let guardians edit VACATION.
    A child Aula hasn't said either way about (configuration unreadable or
    missing) is left out, so Aula decides.
    """
    denials = {
        c.id: "you have no custody of or extended access to this child; a guardian with custody must register it"
        for c in children
        if c.has_custody_or_extended_access is False
    }
    candidates = [c for c in children if c.id not in denials]
    if not candidates:
        return denials
    try:
        configs = await client.get_presence_configuration([c.id for c in candidates])
    except Exception as e:
        if session_gone(e):
            raise
        _LOGGER.warning("Could not fetch presence configuration, leaving it to Aula: %s", e)
        return denials
    by_child = {c.child_id: c for c in configs if c.child_id is not None}
    for child in candidates:
        config = by_child.get(child.id)
        if config is None:
            _LOGGER.warning("No presence configuration for child %s, leaving it to Aula", child.id)
        elif not config.can_edit(PresenceModule.VACATION):
            denials[child.id] = (
                "absence registration is read-only for guardians; contact the institution"
                if config.permission(PresenceModule.VACATION) is PresenceModulePermission.READABLE
                else "the institution has not enabled absence registration for guardians; contact the institution"
            )
    return denials


async def add_absence(client: AulaApiClient, profile: Profile, child_ids: list[int], start: date, end: date, comment: str) -> None:
    """Register a holiday / days off (``client.add_vacation``, the library's
    ``calendar.addVacation``). Its own checks run first so a bad request is a 400."""
    if not child_ids:
        raise BadRequest("childIds is empty")
    known = {c.id: c for c in profile.children}
    for cid in child_ids:
        if cid not in known:
            raise BadRequest(f"unknown child {cid}")
    try:
        validate_vacation(start, end, comment, today=aula_today())
    except ValueError as e:
        raise BadRequest(str(e)) from e
    targets = [known[cid] for cid in dict.fromkeys(child_ids)]
    denials = await _vacation_denials(client, targets)
    if denials:
        cid, reason = next(iter(denials.items()))
        raise BadRequest(f"{known[cid].name or cid}: {reason}")
    await client.add_vacation(list(dict.fromkeys(child_ids)), start, end, comment)


# --- posts -------------------------------------------------------------------


def post_out(post, register: Register) -> dict:
    owner = post.owner
    author = " · ".join(p for p in (owner.full_name or owner.role, owner.institution_name) if p)
    return {
        "id": post.id,
        "title": post.title or "",
        "author": author,
        "authorPicture": picture_id(owner.profile_picture, register),
        "date": iso(post.timestamp),
        "body": plain(post.content_html),
        "important": bool(post.is_important),
        # posts.getAllPosts rows carry isBookmarked (bundle 10.*.js reads post.isBookmarked).
        "saved": bool((post._raw or {}).get("isBookmarked")),
        "attachments": map_attachments(post.attachments, register),
    }


async def posts(client: AulaApiClient, profile: Profile, register: Register, page: int = 1, limit: int = 10) -> list[dict]:
    # A post without a timestamp has no valid "date" for the app; skip it.
    rows = await client.get_posts(profile.institution_profile_ids, page=page, limit=limit)
    return [post_out(p, register) for p in rows if p.timestamp is not None]


# --- gallery -----------------------------------------------------------------


def _gallery_image(url: Any, name: str, register: Register) -> str | None:
    """A gallery URL as an id stable across Aula's re-signed URLs (like ``picture_id``)."""
    if not isinstance(url, str) or not file_url_allowed(url):
        if url:
            _LOGGER.warning("Skipping gallery image on a non-Aula host: %s", urlsplit(str(url)).hostname)
        return None
    return register(url, name, urlsplit(url)._replace(query="", fragment="").geturl())


async def _gallery_get(client: AulaApiClient, method: str, params: dict) -> Any:
    resp = await client._request_with_version_retry("get", client.api_url, params={"method": method, **params})
    resp.raise_for_status()
    return resp.json().get("data")


TAGGED_ALBUM = 0


async def albums(client: AulaApiClient, profile: Profile, register: Register, page: int = 1, limit: int = 20) -> list[dict]:
    data = await _gallery_get(client, "gallery.getAlbums", {
        "index": (page - 1) * limit, "limit": limit, "sortOn": "createdAt", "orderDirection": "desc",
        "filterBy": "all", "filterInstProfileIds[]": profile.institution_profile_ids,
    })
    out = []
    for a in data or []:
        if not isinstance(a, dict) or not (isinstance(a.get("id"), int) or (a.get("id") is None and page == 1)):
            continue
        # Live: on page 1 a row with id null comes first, Aula's virtual album of photos the child is
        # tagged in. It doesn't count towards `limit`; it's served as album 0 (see album_photos).
        thumbs = [u for u in a.get("thumbnailsUrls") or [] if isinstance(u, str)]
        out.append({
            "id": a.get("id") or TAGGED_ALBUM,
            "title": a.get("title") or "",
            "date": iso(a.get("creationDate")),
            "cover": _gallery_image(thumbs[0], "cover.jpg", register) if thumbs else None,
            "tagged": a.get("id") is None,
        })
    return out


async def album_photos(client: AulaApiClient, profile: Profile, album_id: int, register: Register, page: int = 1, limit: int = 60) -> list[dict]:
    # The tagged album has no id: Aula asks for it as userSpecificAlbum without albumId.
    album = {"userSpecificAlbum": "true"} if album_id == TAGGED_ALBUM else {"albumId": album_id, "userSpecificAlbum": "false"}
    data = await _gallery_get(client, "gallery.getMedia", {
        **album, "index": (page - 1) * limit, "limit": limit,
        "sortOn": "uploadedAt", "orderDirection": "desc", "filterBy": "all",
        "filterInstProfileIds[]": profile.institution_profile_ids,
    })
    out = []
    for p in get_in(data, "results", default=None) or []:
        if not isinstance(p, dict) or not isinstance(p.get("id"), int) or p.get("mediaType") != "image":
            continue  # ponytail: videos are left out; show them when someone misses them
        name = get_in(p, "file.name") or "photo.jpg"
        image = _gallery_image(get_in(p, "file.url"), name, register)
        if image is None:
            continue
        # Live sizes (one photo): large 900x1200, medium 600x800, small 300x400 (~55 kB), extraSmall 150x200.
        # Small fills a third of a phone's width at 3x.
        thumb = p.get("smallThumbnailUrl") or p.get("thumbnailUrl")
        out.append({
            "id": p["id"],
            "thumbnail": _gallery_image(thumb, "thumb-" + name, register) or image,
            "image": image,
            "date": iso(get_in(p, "file.created")),
        })
    return out


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


def _row_picture(sender: Any, raw: dict) -> Any:
    """getThreads rows (live) have no picture on creator or latestMessage.sender;
    the same person's entry in recipients (matched by mailbox owner id) has it."""
    owner = get_in(sender, "mailBoxOwner.id")
    match = next((r for r in raw.get("recipients") or [] if isinstance(r, dict) and get_in(r, "mailBoxOwner.id") == owner), None)
    return get_in(sender, "profilePicture") or (get_in(match, "profilePicture") if owner is not None else None)


def thread_out(raw: dict, register: Register | None = None) -> dict:
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
    sender = latest.get("sender") if _sender_name(latest.get("sender")) else raw.get("creator")
    return {
        "id": str(raw.get("id")),
        "subject": raw.get("subject") or "",
        "from": _sender_name(sender) or "",
        # No picture without a register: /today only reads rows for attention items.
        "picture": picture_id(_row_picture(sender, raw), register),
        "participants": len(recipients) or len(raw.get("participants") or []),
        "preview": preview,
        "date": iso(latest.get("sendDateTime") or raw.get("lastUpdatedDate")),
        "unread": not raw.get("read", True),
        "muted": bool(raw.get("muted")),
        "starred": bool(raw.get("marked")),
        "folderId": raw.get("folderId"),
    }


async def threads(
    client: AulaApiClient, page: int = 0, folder: int | None = None, seen: dict[str, dict] | None = None,
    register: Register | None = None,
) -> list[dict]:
    """One page of threads, newest first. Aula's pages are 0-based; past the end it returns none.

    ``folder`` lists one folder: the portal adds ``folderId`` to getThreads'
    params, and leaves it out for the inbox (0.*.js, "inbox"!=t.folderId&&(_.folderId=...)).
    The folder listing is not tried live (the portal also sends mailBoxOwnerIds; we don't).
    ``seen`` collects the raw rows by thread id, for update_thread.
    """
    if page == 0 and folder is None:
        raws = [t._raw or {} for t in await client.get_message_threads()]
    else:
        # The library only reads page 0 of the inbox; same request as its get_all_message_threads_result.
        url = f"{client.api_url}?method=messaging.getThreads&sortOn=date&orderDirection=desc&page={page}"
        if folder is not None:
            url += f"&folderId={folder}"
        resp = await client._request_with_version_retry("get", url)
        resp.raise_for_status()
        raws = [t for t in get_in(resp.json(), "data.threads", default=[]) or [] if isinstance(t, dict)]
    if seen is not None:
        seen.update((str(raw.get("id")), raw) for raw in raws if raw.get("id") is not None)
    # "date" is non-nullable in API.md; a row without any timestamp is skipped.
    rows = [thread_out(raw, register) for raw in raws]
    return [r for r in rows if r["date"]]


async def _post(client: AulaApiClient, method: str, body: dict) -> Any:
    resp = await client._request_with_version_retry("post", f"{client.api_url}?method={method}", json=body)
    resp.raise_for_status()
    return resp.json()


# Folders. Bodies from the portal bundle (app.*.js folder modal, 0.*.js store):
# createFolder {folderName}, updateFolder {folderName, folderId}, deleteFolder {folderId};
# getFolders also returns Aula's own "Slettet post" folder (type "deleted", enum in 0.*.js),
# which is not the user's to rename, delete or move into. Never tried against live Aula
# (the getFolders row shape, incl. "type", is from the bundle, not a logged response).


async def folders(client: AulaApiClient) -> list[dict]:
    rows = await client.get_message_folders()
    return [
        {"id": f.id, "name": f.name}
        for f in rows
        if (f._raw or {}).get("type", "normal") == "normal"
    ]


def folder_name(name: str) -> str:
    name = name.strip()
    if not 1 <= len(name) <= 100:  # the portal's isValidFolderName
        raise BadRequest("name must be 1–100 characters")
    return name


async def _folder(client: AulaApiClient, folder_id: int) -> dict:
    found = next((f for f in await folders(client) if f["id"] == folder_id), None)
    if found is None:
        raise NotFound(f"folder {folder_id}")
    return found


async def create_folder(client: AulaApiClient, name: str) -> dict:
    name = folder_name(name)
    before = {f["id"] for f in await folders(client)}
    await _post(client, "messaging.createFolder", {"folderName": name})
    # The portal ignores the answer and reloads the folders; so do we.
    new = [f for f in await folders(client) if f["id"] not in before]
    found = next((f for f in new if f["name"] == name), new[0] if new else None)
    if found is None:
        raise UpstreamFailure("Aula did not show the new folder")
    return found


async def rename_folder(client: AulaApiClient, folder_id: int, name: str) -> dict:
    name = folder_name(name)
    await _folder(client, folder_id)
    await _post(client, "messaging.updateFolder", {"folderName": name, "folderId": folder_id})
    return {"id": folder_id, "name": name}


async def delete_folder(client: AulaApiClient, folder_id: int) -> None:
    """Aula deletes the folder's messages with it (portal's confirm text)."""
    await _folder(client, folder_id)
    await _post(client, "messaging.deleteFolder", {"folderId": folder_id})


async def update_thread(
    client: AulaApiClient, seen: dict[str, dict], thread_id: str, changes: dict[str, Any], register: Register
) -> dict:
    """Mute, star ("marked") and move one thread, like the portal's swipe
    actions on a thread row (app.*.js subscription list item), which all name
    the row's subscriptionId, never the thread id:

    - setThreadsMuted {muted, subscriptionIds:[s], commonInboxId:null, otpInboxId:null}
      (setThreadMutedStatus)
    - setThreadsMarked {threadIds:[], subscriptionIds:[s], marked, commonInboxId:null, otpInboxId:null}
      (markSubscriptionToggle -> SWITCH_MARK_SUBSCRIPTIONS in 0.*.js)
    - moveThreadsToFolder {folderId, threadIds:[], subscriptionIds:[s], commonInboxId:null}
      (move-to-folder-modal subscription-ids -> MOVE_THREADS_TO_FOLDER; null = inbox)

    The subscription id is only in getThreads rows (not in getMessagesForThread),
    so the row must have been listed. Never tried against live Aula.
    """
    raw = seen.get(thread_id)
    if raw is None:
        await threads(client, 0, seen=seen)
        raw = seen.get(thread_id)
    subscription_id = (raw or {}).get("subscriptionId")
    if subscription_id is None:
        raise Conflict("Thread not in the listed threads; reload the list and try again")
    if changes.get("folderId") is not None and changes["folderId"] not in {f["id"] for f in await folders(client)}:
        raise BadRequest(f"unknown folder {changes['folderId']}")
    raw = seen[thread_id] = dict(raw)  # a copy, updated as each write lands
    if "muted" in changes:
        await _post(client, "messaging.setThreadsMuted", {
            "muted": changes["muted"], "subscriptionIds": [subscription_id], "commonInboxId": None, "otpInboxId": None,
        })
        raw["muted"] = changes["muted"]
    if "starred" in changes:
        await _post(client, "messaging.setThreadsMarked", {
            "threadIds": [], "subscriptionIds": [subscription_id], "marked": changes["starred"],
            "commonInboxId": None, "otpInboxId": None,
        })
        raw["marked"] = changes["starred"]
    if "folderId" in changes:
        await _post(client, "messaging.moveThreadsToFolder", {
            "folderId": changes["folderId"], "threadIds": [], "subscriptionIds": [subscription_id], "commonInboxId": None,
        })
        raw["folderId"] = changes["folderId"]
    return thread_out(raw, register)


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
            "picture": picture_id(get_in(m, "sender.profilePicture"), register),
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
