# Sala API (server ⇄ iOS)

The contract between `server/` and `ios/`. Both sides follow this file; change it here first.

All endpoints need `Authorization: Bearer <SALA_TOKEN>`. Missing or wrong token → `401 {"error":"unauthorized"}`.
When the Aula session is gone and a MitID login is needed → `503 {"error":"auth_required"}` (client shows the login screen, see `/auth/*`).
A write that makes no sense in today's state → `409 {"error":"conflict","message":"..."}`.
Other upstream failures → `502 {"error":"upstream","message":"..."}`. JSON keys are camelCase. Dates are `YYYY-MM-DD`, timestamps ISO 8601 with offset, times `HH:mm`.

## Auth (MitID, held by the server)

`GET /auth/status` →
```json
{"state":"ok|needs_login|logging_in|error","otpCode":"123456|null","qr":[["0101…"],["1100…"]],"message":"string|null","since":"timestamp|null"}
```
- `needs_login`: no valid session; nothing running. Client offers "Log in with MitID".
- `logging_in`: a MitID request was sent to the MitID app. `otpCode` is set when MitID asks the user to type a code into the app. `qr` is set while MitID wants its QR code scanned: two halves, each a list of rows of `"0"`/`"1"` modules. Show them alternating in one spot, about a second each, on a white background.
- `error`: last login failed; `message` says why. The server never retries on its own.

`POST /auth/login` → starts one login (single-flight; calling it again while `logging_in` is a no-op). Returns the status object.

## Today

`GET /today` →
```json
{
  "date": "2026-11-12",
  "children": [{
    "id": 123,
    "name": "Oskar",
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
{"id": 9, "title": "Welcome", "author": "Leder · Børnehuset", "date": "timestamp", "body": "plain text", "important": false, "saved": false,
 "attachments": [Attachment]}
```
`Attachment`:
```json
{"id": "a1b2", "name": "Præsentation.pdf", "kind": "file|image|link", "url": "https://… (links only)"}
```
- `file` / `image`: an Aula file; fetch it with `GET /attachments/{id}`. No `url`.
- `link`: a cloud-drive link the author attached. `id` is null and `url` is the link; open it in the browser. The server never fetches it.

Nullable: `arrivedAt`, `leftAt`, `pickup.time`, `pickup.by`, `closesAt`, `threadId`, `subtitle`, Attachment `id` (links), and `threadId` in the `sender` reply response when Aula doesn't return the new thread's id. Every other field is always present and non-null; posts, threads and messages Aula sends without a timestamp are left out.

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

`POST /absences` body `{"childIds":[123],"startDate":"2026-12-27","endDate":"2026-12-30","comment":""}` → `{"ok":true}`. Registers a holiday or days off (Aula's "Ferie/fri"). `endDate` may equal `startDate` for one day. Start in the past, end before start, end more than a year after start, a comment over 250 characters, no children, an unknown child, or a child Aula won't take an absence for (no custody, or the institution doesn't let guardians register absences; when that can't be read, Aula decides) → `400` with the reason in `message`. There is no listing or cancelling.

## Posts

`GET /posts?page=N` → `[Post]`, newest first, 10 per page. `page` is 1-based (default 1, at most 100, else `400`); page 1 is the `posts` of `/today`. An empty list means there are no more posts.

`POST /posts/{id}/save` / `DELETE /posts/{id}/save` → `{"saved": true|false}`.
`GET /attachments/{id}` → the file bytes with its `Content-Type` and `Content-Disposition: inline; filename=...`. `id` is an opaque server-issued id from a Post or Message; the server never fetches a client-supplied URL, only Aula file URLs on Aula's own hosts (https, `*.aula.dk`), and follows redirects only onto those hosts.

## Messages

`GET /threads` →
```json
[{"id":"123","subject":"Forældremøde","from":"Leder","participants":57,"preview":"Parent meeting…","date":"timestamp","unread":true,"muted":false,"starred":false}]
```
`GET /threads?page=N` → one page of threads, newest first. `page` is 0-based like Aula's (default 0, at most 100, else `400`). An empty list means there are no more threads. Page size is Aula's; the client should not assume it.
`GET /threads/{id}` (also marks it read) →
```json
{"id":"123","subject":"Forældremøde","canReply":true,
 "messages":[{"id":"m1","sender":"Leder","fromMe":false,"date":"timestamp","text":"plain text","attachments":[Attachment]}]}
```
`POST /threads/{id}/reply` body `{"text":"...","audience":"everyone|sender","messageId":"m1"}` → `{"ok":true,"threadId":"..."}`.
- `everyone`: a reply in the thread to all participants (`messaging.reply`).
- `sender`: a new thread to the sender of `messageId` only (Aula's "Svar afsender direkte", `messaging.startNewThread`). `threadId` is the new thread's id. `messageId` is required, and must not be one of the user's own messages.

## Push

There is no push endpoint. Push goes through [ntfy](https://ntfy.sh): the server polls Aula every `POLL_SECONDS` and publishes to the ntfy topic `NTFY_TOPIC`; the phone subscribes to that topic in the ntfy iOS app. Push is off when `NTFY_TOPIC` is unset.

Notifications (titles only, never message or post bodies):

| Event | Title | Priority | Click |
| --- | --- | --- | --- |
| New message (not from me) in a thread with me and exactly one other person | `New message from Mette Lund` (`New message` when the sender can't be determined) | default | `sala://thread/<threadId>` |
| New important post | `Important post: <post title>` | default | `sala://today` |
| New unanswered holiday request (held until 07:00 when its deadline is today or tomorrow) | `Holiday request 21–23 Dec · answer by 13 Nov` | high when the deadline is 2 days away or less | `sala://today` |
| Unanswered holiday request, the day before its deadline, from 07:00 (not sent when the new-request notification above goes out in the same poll) | `Holiday request 21–23 Dec · answer by tomorrow` | high | `sala://today` |
| Unanswered holiday request, on its deadline day, from 07:00 (same rule) | `Holiday request 21–23 Dec · answer today` | high | `sala://today` |
| Aula session lost (once per loss, retried until delivered, not repeated after a server restart) | `Aula login needed` | high | `sala://today` |

Items that exist when push is first enabled never notify. Each reminder is sent at most once, only on its own day: a reminder ntfy refused is retried on later polls that same day, never after it, and never after the deadline. The app handles the `sala://` links (`thread/<id>` opens the thread, `today` the Today tab).
