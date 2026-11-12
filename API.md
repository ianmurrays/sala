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

## Posts

`POST /posts/{id}/save` / `DELETE /posts/{id}/save` → `{"saved": true|false}`.
`GET /attachments/{id}` → the file bytes with its `Content-Type` and `Content-Disposition: inline; filename=...`. `id` is an opaque server-issued id from a Post or Message; the server never fetches a client-supplied URL, only Aula file URLs on Aula's own hosts (https, `*.aula.dk`), and follows redirects only onto those hosts.

## Messages

`GET /threads` →
```json
[{"id":"123","subject":"Forældremøde","from":"Leder","participants":57,"preview":"Parent meeting…","date":"timestamp","unread":true,"muted":false,"starred":false}]
```
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
| New unanswered holiday request | `Holiday request 21–23 Dec · answer by 13 Nov` | high when the deadline is 2 days away or less | `sala://today` |
| Aula session lost (once per loss, retried until delivered, not repeated after a server restart) | `Aula login needed` | high | `sala://today` |

Items that exist when push is first enabled never notify. The app handles the `sala://` links (`thread/<id>` opens the thread, `today` the Today tab).
