# Sala API (server ⇄ iOS)

The contract between `server/` and `ios/`. Both sides follow this file; change it here first.

All endpoints need `Authorization: Bearer <SALA_TOKEN>`. Missing or wrong token → `401 {"error":"unauthorized"}`.
When the Aula session is gone and a MitID login is needed → `503 {"error":"auth_required"}` (client shows the login screen, see `/auth/*`).
Other upstream failures → `502 {"error":"upstream","message":"..."}`. JSON keys are camelCase. Dates are `YYYY-MM-DD`, timestamps ISO 8601 with offset, times `HH:mm`.

## Auth (MitID, held by the server)

`GET /auth/status` →
```json
{"state":"ok|needs_login|logging_in|error","otpCode":"123456|null","qr":null,"message":"string|null","since":"timestamp|null"}
```
- `needs_login`: no valid session; nothing running. Client offers "Log in with MitID".
- `logging_in`: a MitID request was sent to the MitID app. `otpCode` is set when MitID asks the user to type a code into the app.
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
 "attachments": [{"id": "a1b2", "name": "Præsentation.pdf", "kind": "file|image"}]}
```
Nullable: `arrivedAt`, `leftAt`, `pickup.time`, `pickup.by`, `closesAt`, `threadId`, `subtitle`.

## Pickup and sick

`GET /children/{id}/pickup` →
```json
{"date":"2026-11-12","opensAt":"06:30","closesAt":"16:45","times":["15:30","16:00","16:15","16:30","16:45"],
 "people":["Jonas (Far)","Mor (Mor)"],"current":{"time":"16:15","by":"Jonas (Far)"},"note":""}
```
`PUT /children/{id}/pickup` body `{"time":"16:15","by":"Jonas (Far)","note":""}` → the updated child object (same shape as in `/today`). Changes today only; `by` must be one of `people`, else `400`.

`POST /children/{id}/sick` → updated child (status `sick`). `DELETE /children/{id}/sick` → takes the report back, returns the updated child.

## Posts

`POST /posts/{id}/save` / `DELETE /posts/{id}/save` → `{"saved": true|false}`.
`GET /attachments/{id}` → the file bytes with its `Content-Type` and `Content-Disposition: inline; filename=...`. `id` is an opaque server-issued id from a Post or Message; the server never fetches a client-supplied URL.

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

`POST /devices` body `{"token":"<apns hex>"}` → `{"ok":true}`. The server polls Aula and sends APNs pushes for new direct messages, new important posts and new holiday requests. Payload carries `{"kind":"message|post|holiday_request","threadId"?,"postId"?}` next to `aps`.
