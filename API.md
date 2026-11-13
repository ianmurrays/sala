# Sala API (routes ⇄ views)

The app has no server: `ios/Sala/Aula/AulaRoutes.swift` (`Aula.handle`) answers these routes in-process against Aula, and `ios/Sala/API.swift` (`APIClient`) calls them and decodes the answers. The routes are a port of the old Python server, so this file still reads like an HTTP API: paths, JSON bodies and status codes map one to one onto `APIError`. Change it here first.

No Aula session (no login yet, or Aula ended it) → `APIError.authRequired` (the app shows the MitID login, see `ios/Sala/LoginView.swift`).
A write that makes no sense in today's state → `409 {"error":"conflict","message":"..."}`.
Other upstream failures → `502 {"error":"upstream","message":"..."}`. JSON keys are camelCase. Dates are `YYYY-MM-DD`, timestamps ISO 8601 with offset, times `HH:mm`.

## Today

`GET /today` →
```json
{
  "date": "2026-11-12",
  "children": [{
    "id": 123,
    "name": "Oskar",
    "picture": "f31f36216c15",
    "institution": "Børnehuset",
    "group": "Stue",
    "status": "present|not_arrived|sick|gone_home|vacation|unknown",
    "statusLabel": "Present",
    "arrivedAt": "07:40",
    "leftAt": null,
    "pickup": {"time": "16:15", "by": "Jonas (Far)"},
    "closesAt": "16:45",
    "canReportSick": true
  }],
  "attention": [{
    "id": "vacation-55",
    "kind": "holiday_request|message",
    "title": "Holiday request: 21–23 Dec",
    "subtitle": "Answer by 13 Nov",
    "urgent": true,
    "threadId": null
  }],
  "upcoming": [{"date": "2026-11-20", "title": "Birthday in the group", "subtitle": "Stue"}],
  "posts": [Post]
}
```
`Post`:
```json
{"id": 9, "title": "Welcome", "author": "Leder · Børnehuset", "authorPicture": "9c1d…", "date": "timestamp", "body": "plain text", "important": false, "saved": false,
 "attachments": [Attachment]}
```
`Attachment`:
```json
{"id": "a1b2", "name": "Præsentation.pdf", "kind": "file|image|link", "url": "https://… (links only)"}
```
- `file` / `image`: an Aula file; fetch it with `GET /attachments/{id}`. No `url`.
- `link`: a cloud-drive link the author attached. `id` is null and `url` is the link; open it in the browser. Sala never fetches it.

Profile pictures: `picture` (child, thread summary, message) and `authorPicture` (post) are opaque ids for `GET /attachments/{id}`, `null` when the person has no picture. Draw initials when it is `null` or the fetch fails. The id stays the same while the picture does (Aula's URL may be re-signed on every load), so the client can cache the image by id. `GET /attachments/{id}` sends `Cache-Control: private, max-age=604800` (a week).

Nullable: `arrivedAt`, `leftAt`, `pickup.time`, `pickup.by`, `closesAt`, `threadId`, `subtitle`, Attachment `id` (links), `picture`, `authorPicture`, and `threadId` in the `sender` reply response when Aula doesn't return the new thread's id. Every other field is always present and non-null; posts, threads and messages Aula sends without a timestamp are left out.

## Pickup and sick

`GET /children/{id}/pickup` →
```json
{"date":"2026-11-12","opensAt":"06:30","closesAt":"16:45","times":["15:30","16:00","16:15","16:30","16:45"],
 "people":["Jonas (Far)","Mor (Mor)"],"current":{"time":"16:15","by":"Jonas (Far)"},"note":""}
```
Nullable here: `opensAt`, `closesAt`, `current.time`, `current.by`.

`PUT /children/{id}/pickup` body `{"time":"16:15","by":"Jonas (Far)","note":""}` → the updated child object (same shape as in `/today`). Changes today only. `time` must be a valid `HH:mm` and `by` one of `people`, else `400`. When the child is registered absent today (vacation) → `409 {"error":"conflict","message":"Oskar is registered absent today"}` and nothing is written.

`POST /children/{id}/sick` → updated child (status `sick`). `DELETE /children/{id}/sick` → takes the report back, returns the updated child: status goes back to present if the child was checked in today and not checked out, otherwise to not arrived.

## Holidays

`GET /holiday-requests/{id}` (`id` is the attention item's `id`, e.g. `vacation-55`) →
```json
{"id":"vacation-55","title":"Juleferie","note":"Giv besked om Oskar holder fri.","deadline":"2026-11-13",
 "startDate":"2026-12-21","endDate":"2026-12-23","timesRequired":false,"answered":false,"editable":true,
 "children":[{"id":123,"name":"Oskar","answered":false,"comment":"",
   "days":[{"date":"2026-12-21","coming":null,"entryTime":null,"exitTime":null,"editable":true}]}]}
```
- One entry in `children` per child the request is for. `days` are the weekdays from `startDate` to `endDate`, as in Aula's own form.
- `coming` is the current answer (`null` = not answered). `editable` is false for days that are today or past, days the institution is closed, every day once the deadline has passed, and every day of a child Aula says you have no custody of. Those days are not sent.
- `answered` is true when every child has an answer. `editable` (top level) is false once the deadline has passed; then a `POST` → `409`.
- `timesRequired`: the institution wants drop-off and pickup times for the days the child comes.
- Nullable: `note`, `deadline`, `startDate`, `endDate`, `days[].coming`, `days[].entryTime`, `days[].exitTime`.

`POST /holiday-requests/{id}` body
```json
{"children":[{"id":123,"days":[{"date":"2026-12-21","coming":true,"entryTime":"08:00","exitTime":"15:00"}],"comment":""}]}
```
→ the updated request (same shape as `GET`).
- Answer one or more of the request's children. For each, every editable day must have an answer. A day that isn't listed or isn't editable, an unknown child, or a time that isn't `HH:mm` → `400`.
- Times are only used when `timesRequired`. Then a day with `coming: true` needs both `entryTime` and `exitTime`, with entry before exit, else `400`. Otherwise times are ignored, like Aula's form.
- `comment` is per child (Aula keeps one per child's answer); a missing `comment` is sent as empty, replacing that child's previous one.

`POST /absences` body `{"childIds":[123],"startDate":"2026-12-27","endDate":"2026-12-30","comment":""}` → `{"ok":true}`. Registers a holiday or days off (Aula's "Ferie/fri"). `endDate` may equal `startDate` for one day. Start in the past, end before start, end more than a year after start, a comment over 250 characters, no children, an unknown child, or a child Aula won't take an absence for (no custody, or the institution doesn't let guardians register absences; when that can't be read, Aula decides) → `400` with the reason in `message`.

`GET /holiday-requests` → the requests that can still be answered (Aula marks them editable and the deadline is today or later, or none), answered or not, by deadline:
```json
[{"id":"vacation-55","title":"Juleferie","startDate":"2026-12-21","endDate":"2026-12-23","deadline":"2026-11-13","answered":true}]
```
Open one with `GET /holiday-requests/{id}`; `POST` changes the answer until the deadline. Nullable: `startDate`, `endDate`, `deadline`.

`GET /absences` → the registered holidays and days off that haven't ended, by start date:
```json
[{"id":"absence-9001","children":[{"id":123,"name":"Oskar"}],"startDate":"2026-12-27","endDate":"2026-12-30","comment":"Skiferie","editable":true}]
```
- One entry per Aula absence, with the children it is for.
- `editable` is false when Aula says the absence can't be changed, or you have no custody of a child in it.

`PUT /absences/{id}` body `{"startDate":"2026-12-28","endDate":"2026-12-30","comment":""}` → `{"ok":true}`. Changes the dates or comment. The `POST /absences` rules apply, except that an unchanged start date may be in the past (an absence that has started can be shortened). An unknown `id` → `404`; not `editable` → `409`; a changed start date Aula no longer allows (the absence has started) → `400`; an end date in the past → `400`.

`DELETE /absences/{id}` → `{"ok":true}`. Cancels the absence. An unknown `id` → `404`; not `editable` → `409` (stricter than Aula's portal, which offers delete on locked ones too).

## Calendar

`GET /calendar?month=2026-12` → what is on in that month (Europe/Copenhagen), sorted by `startDate`, all-day first, then `startTime`:
```json
[{"id":"event-9001-2026-12-23","kind":"absence","title":"Ferie/fri","subtitle":"Oskar",
  "startDate":"2026-12-23","endDate":"2026-12-23","startTime":null,"endTime":null}]
```
- `month` is `YYYY-MM`, default the current month; anything else → `400`.
- Every event that touches the month is listed, so one spanning two months comes back for both. `id` is stable across loads and months (it holds the occurrence's start date, so each occurrence of a repeating event has its own); deduplicate by it.
- `kind`:
  - `absence`: a registered holiday or day off (Aula's "Ferie/fri", including holiday requests answered "not coming"). `subtitle` is the children's names.
  - `meeting`: an event to book a time for (a school–home meeting). Booked: the booked slot's date and times. Not booked: the booking window's dates, no times, `subtitle` "Not booked".
  - `birthday`: a child in the institution. `subtitle` is the group.
  - `event`: anything else Aula puts in the calendar. `subtitle` is the institution.
- `endDate` is inclusive. `startTime` and `endTime` are `HH:mm`, both `null` for an all-day item.
- Nullable: `subtitle`, `startTime`, `endTime`.

## Posts

`GET /posts?page=N` → `[Post]`, newest first, 10 per page. `page` is 1-based (default 1, at most 100, else `400`); page 1 is the `posts` of `/today`. An empty list means there are no more posts.

`POST /posts/{id}/save` / `DELETE /posts/{id}/save` → `{"saved": true|false}`.
`GET /attachments/{id}` → the file bytes with its `Content-Type` and `Content-Disposition: inline; filename=...`. `id` is an opaque id from a Post, Message, profile picture or the gallery (in Swift: `Aula.attachment(id)`); Sala never fetches a URL it wasn't given by Aula, only Aula file URLs on Aula's own hosts (https, `*.aula.dk`), and follows redirects only onto those hosts.

## Gallery

`GET /albums?page=N` → the institution's photo albums, newest first, 20 per page:
```json
[{"id": 7001, "title": "Skovtur", "date": "timestamp|null", "cover": "e3b0c4…|null", "tagged": false}]
```
`GET /albums/{id}/photos?page=N` → the photos in one album, newest first, 60 per page:
```json
[{"id": 8001, "thumbnail": "9f86d0…", "image": "2c26b4…", "date": "timestamp|null"}]
```
- `page` is 1-based (default 1, at most 100, else `400`). An empty list means there are no more.
- `cover`, `thumbnail` and `image` are ids for `GET /attachments/{id}`, stable across loads like profile pictures, so the client can cache them. `thumbnail` is Aula's small size (300×400 for a 1200×1600 photo, about 55 kB); `image` is the original, for the viewer and for saving. `thumbnail` is the same id as `image` when Aula has no thumbnail.
- Videos are left out, so a page can hold fewer than 60 photos. A page of nothing but videos comes back empty, and the client stops there (rare enough to accept).
- Page 1 starts with Aula's album of photos the child is tagged in: `"tagged": true`, `id` 0 (Aula gives it none), title from Aula. `GET /albums/0/photos` lists it.
- A photo's `date` is when it was uploaded.
- Aula's image URLs are signed and expire; listing the album again refreshes the ones Sala fetches.

## Search

`GET /search?q=<text>&type=messages|posts|photos&page=N` → Aula's global search (the portal's search box), one type per call, 20 per page:
```json
{"counts": {"messages": 17, "posts": 16, "photos": 74},
 "messages": [{"id": "m9", "threadId": "123", "subject": "Forældremøde", "from": "Leder", "preview": "Parent meeting…", "date": "timestamp"}],
 "posts": [Post],
 "photos": [Photo]}
```
- `counts` is how many hits Aula has for `q` of each type, whatever `type` asks for; the client shows a type only when its count is above 0. Only the list for `type` is filled, the other two are empty.
- `q` is trimmed; empty → `400`. `type` defaults to `messages`; anything else → `400`. `page` is 1-based (default 1, at most 100, else `400`). An empty list means there are no more. Order is Aula's.
- `messages`: `id` is the matching message, `threadId` its thread (open it with `GET /threads/{id}`), `date` when that message was sent (Aula names it `latestMessageSendTime`; live it matched the message `findMessage` returns for the thread). A result's thread may not be in `/threads`, so `PATCH /threads/{id}` can answer `409` for it.
- `posts`: the `Post` shape of `/posts`, except `saved` is always `false` (Aula's search doesn't say); saving isn't offered from search.
- `photos`: the `Photo` shape of the gallery; videos are left out, as in albums.
- Calendar events, people, groups and files are not searched: Aula's search found no events in the searches tried, and people are in Contacts.

## Contacts

Aula's contact book (Kontaktbog). Other families' personal data: the app keeps it only while the screen is open, and never logs or caches it.

`GET /contacts/groups` → the groups of each child (class, kindergarten room), one entry per child and group:
```json
[{"id": 77, "name": "Stue", "child": "Oskar"}]
```
`GET /contacts/groups/{id}` → who is in the group, sorted by name as Aula sorts:
```json
{"children": [{"id": 3001, "name": "Ida Jensen", "guardians": [Contact]}],
 "staff": [Contact]}
```
`Contact`:
```json
{"name": "Mette Jensen", "relation": "Mor", "shared": true,
 "phones": [{"label": "Mobile", "number": "+45 12 34 56 78"}], "email": "mette@example.dk", "address": "Bøgevej 3, 2100 København Ø"}
```
- `shared` is false when the person doesn't let Aula show their contact details to you; then `phones` is empty and `email` and `address` are null. A missing phone, e-mail or address is normal: parents choose what they share.
- `phones[].label` is `Home`, `Mobile` or `Work` (for a group home: `Primary`, `Secondary`; no home number).
- `relation` is the guardian's relation to the child as Aula writes it ("Mor", "Far"), null for staff and when Aula has none.
- `id` is not a number → `400`. A group Aula won't show → `502`.
- Nullable: `relation`, `email`, `address`.

## Messages

`GET /threads` →
```json
[{"id":"123","subject":"Forældremøde","from":"Leder","picture":null,"participants":57,"preview":"Parent meeting…","date":"timestamp","unread":true,"muted":false,"starred":false,"folderId":null}]
```
`GET /threads?page=N` → one page of threads, newest first. `page` is 0-based like Aula's (default 0, at most 100, else `400`). An empty list means there are no more threads. Page size is Aula's; the client should not assume it.
`GET /threads?folder=<id>&page=N` → the same for one folder (an `id` from `/folders`). Without `folder` it's the inbox. `folderId` (nullable) is the folder the thread is in, `null` in the inbox.

`PATCH /threads/{id}` body with any of `{"muted":true,"starred":true,"folderId":71}` → the updated thread summary (same shape as in `/threads`).
- `starred` is Aula's "marked". `folderId: null` moves the thread back to the inbox; a `folderId` that isn't one of `/folders` → `400`. An empty body → `400`.
- Each field is its own Aula call, in the order muted, starred, folderId; if one fails (`502`) the ones before it are done.
- Sala acts on threads it has listed in `/threads` (it needs Aula's subscription id from the list row). A thread it hasn't listed since it started, and that isn't on the inbox's first page → `409`; reload the list and try again. The returned summary is that list row with the change applied.
`GET /threads/{id}` (also marks it read) →
```json
{"id":"123","subject":"Forældremøde","canReply":true,
 "messages":[{"id":"m1","sender":"Leder","picture":"9c1d…","fromMe":false,"date":"timestamp","text":"plain text","attachments":[Attachment]}]}
```
`POST /threads/{id}/reply` body `{"text":"...","audience":"everyone|sender","messageId":"m1"}` → `{"ok":true,"threadId":"..."}`.
- `everyone`: a reply in the thread to all participants (`messaging.reply`).
- `sender`: a new thread to the sender of `messageId` only (Aula's "Svar afsender direkte", `messaging.startNewThread`). `threadId` is the new thread's id. `messageId` is required, and must not be one of the user's own messages.

## Folders

`GET /folders` → `[{"id":71,"name":"Skole"}]`, the user's own folders (not Aula's "Slettet post" folder).
`POST /folders` body `{"name":"Skole"}` → the new folder `{"id":72,"name":"Skole"}`. `PATCH /folders/{id}` body `{"name":"..."}` → the renamed folder. The name is trimmed and must be 1–100 characters, else `400`. An unknown folder → `404`.
`DELETE /folders/{id}` → `{"ok":true}`. Per Aula's own confirmation text ("Hvis denne mappe ikke er tom, vil alle beskeder i mappen blive slettet"; not tried live), the messages in the folder are deleted with it, not moved to the inbox. The client should say so before deleting.

## Translation and summaries

Not routes. The app translates or summarizes one message or post on a tap, in `ios/Sala/AI.swift`, with what Settings → AI picks: Apple's model on the phone, an OpenAI-compatible endpoint, or the Anthropic API. Off by default.

## Push

Local notifications from iOS background refresh (`ios/Sala/BackgroundRefresh.swift`, rules in `ios/Sala/Aula/AulaPush.swift`), best effort: iOS decides when it runs. Turned on in Settings. These were the old server's rules (it pushed through ntfy), the spec to keep (titles only, never message or post bodies). Differences on the phone: "not from me" is the thread being unread (live `getThreads` rows carry no `latestMessage.sender`, and reading the thread could mark it read); there is no priority (a time-sensitive notification needs an entitlement); a reminder held until 07:00 is scheduled for 07:00; a deliberate logout does not notify.

| Event | Title | Priority | Click |
| --- | --- | --- | --- |
| New message (not from me) in an unmuted thread with me and exactly one other person | `New message from Mette Lund` (`New message` when the sender can't be determined) | default | `sala://thread/<threadId>` |
| New important post | `Important post: <post title>` | default | `sala://today` |
| New unanswered holiday request (held until 07:00 when its deadline is today or tomorrow) | `Holiday request 21–23 Dec · answer by 13 Nov` | high when the deadline is 2 days away or less | `sala://today` |
| Unanswered holiday request, the day before its deadline, from 07:00 (not sent when the new-request notification above goes out in the same poll) | `Holiday request 21–23 Dec · answer by tomorrow` | high | `sala://today` |
| Unanswered holiday request, on its deadline day, from 07:00 (same rule) | `Holiday request 21–23 Dec · answer today` | high | `sala://today` |
| Aula session lost (once per loss) | `Aula login needed` | high | `sala://today` |

Items that exist when notifications are first enabled never notify. Each reminder is sent at most once, only on its own day, and never after the deadline. The app handles the `sala://` links (`thread/<id>` opens the thread, `today` the Today tab).
