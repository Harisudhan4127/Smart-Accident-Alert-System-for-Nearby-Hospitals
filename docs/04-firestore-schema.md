# 04 — Firestore schema

Four collections, one subcollection, one rules file. Everything below is
enforced by `backend/firestore.rules` and written by
`backend/functions/src/index.ts`.

## Why the app has almost no Firestore code

`app/lib/` contains **no** Firestore query. The app calls two Cloud Functions
and reads nothing directly except its own documents, which it does not write
either — the profile is a planned feature. Two consequences worth internalising:

- Every schema decision lives in the functions, not in the app. The app has
  `AccidentRecord` and `Hospital` domain entities that mirror these fields, and
  the mapping is done by hand in the function.
- `firestore.rules` protects a system that mostly does not use Firestore yet.
  It is written for the day the app writes directly, and it is the part of this
  repository with the least verification — see [09](09-security-and-privacy.md)
  and [10](10-testing.md).

## Collections

```
  users/{userId}
    ├── name                     string,  1–120
    ├── phone                    string,  6–24
    ├── vehicleNumber            string,  1–24
    ├── emergencyContacts[]      ≤10 × { id, name, phone, relationship? }
    ├── notificationPermissionGranted   bool
    ├── createdAt                timestamp == request.time
    └── updatedAt                timestamp == request.time

  accidents/{accidentId}
    ├── userId                   string,  immutable, == auth.uid on create
    ├── status                   DETECTED | CANCELLED | CONFIRMED | ALERT_SENT | RESOLVED
    ├── impactValue              number,  0–1000   (g)
    ├── latitude                 number,  -90..90
    ├── longitude                number,  -180..180
    ├── accuracyM                number,  0–100000
    ├── occurredAt               timestamp
    ├── createdAt                timestamp == request.time
    ├── updatedAt                timestamp == request.time
    ├── dispatchedAt             timestamp   (server-written)
    ├── deviceId?                string ≤64
    ├── hospitalId?              string ≤64
    ├── hospitalName?            string ≤160
    ├── hospitalRating?          number 0–5
    ├── hospitalDistanceM?       number 0–200000
    ├── impactG?                 number 0–1000
    ├── impactScore?             int    0–100
    ├── detectedDeviceState?     string ≤16
    ├── notifiedContactIds?      ≤10 × string
    ├── grants/{hospitalId}      { grantedAt, reason, expiresAt? }
    └── attachments/{fileName}   ≤5 MiB, image/(jpeg|png|webp)

  hospitals/{hospitalId}
    ├── name                     string,  1–160
    ├── address                  string,  1–300
    ├── latitude                 number,  -90..90
    ├── longitude                number,  -180..180
    ├── phone                    string,  6–24
    ├── type?                    EMERGENCY | MULTI_SPECIALTY | CLINIC | OTHER
    ├── beds?                    int,  0–100000
    ├── hasEmergency?            bool
    ├── rating?                  number,  0–5
    ├── geohashPrefixes[]        1–4 × string, 4–8 chars
    └── isAnchor?                bool
```

## Field-by-field reasoning

### `accidents`

**`userId` is immutable.** `validUpdate` re-asserts
`request.resource.data.userId == resource.data.userId` and the `affectedKeys`
allow-list does not include `userId`. If ownership could be rewritten, every
other check in the file would be decorative: a user could hand their record to
themselves out of another account's collection and then read it.

**`latitude`/`longitude` are flat, not a `GeoPoint`.** This matches the app's
`Hospital` entity and the seed data, so the mapping is one-to-one with no
transformation. It also means a `GeoPoint` field in a rule would be a different
field, not a compatible one — `data.latitude is number` would reject it.

**`accuracyM` is capped at 100 km.** A "fix" with 100 km accuracy is a cell-tower
guess, not a position. The app still shows it, labelled, but a record cannot
claim metre-level precision it does not have.

**`status` follows §18 and nothing else.** `validTransition` encodes the graph:

```
  DETECTED ──► CANCELLED
      │
      └─────► CONFIRMED ──► ALERT_SENT ──► RESOLVED
```

Same-status updates are always allowed, because a client frequently rewrites
other fields. `UNKNOWN` is not a legal value: the app maps an unrecognised
status to an inert terminal value on *read*, but no client may *write* one,
since writing it is indistinguishable from corrupting the record.

**`impactValue` is in g, 0–1000.** The node measures in mg and the function
converts. The ceiling is generous on purpose: a phone in the footwell reads
several g, and a rule that rejected the reading would teach the client to clamp
it and lie about severity.

**`createdAt`/`updatedAt` must equal `request.time`.** Client-supplied
timestamps are how backdated records appear in an audit. The only timestamp a
client may influence is `occurredAt`, and only because it carries the node's
uptime-derived estimate; `createdAt` is the server's word on when the record
arrived.

**`hospitalId` does not notify anyone.** It records which facility the driver
chose from the list. See "The grant is not a notification" below.

### `accidents/{id}/grants/{hospitalId}`

```
  { grantedAt: server timestamp, reason: fixed string, expiresAt?: timestamp }
```

- Readable by the accident owner or by the grant id's holder, which for a
  hospital means a future staff account with that id.
- `reason` is written by the server with fixed wording, so a client cannot
  author an audit entry that reads as though a clinician had acted.
- **`update` is `false`.** A grant is revoked by deleting it. An edit would
  leave the audit trail showing the grant that was consented to rather than the
  one that was withdrawn.
- `hasOnly(['grantedAt', 'reason', 'expiresAt'])` — nothing else can be
  attached to a grant.

### `hospitals`

Public `get`/`list`, admin-only write. §16 allows a predefined list for the
prototype, and the search has to work before sign-in and from a read-only kiosk.
A hospital record holds no personal data.

`validHospital`'s `hasOnly` list is **exactly** the key set
`backend/seed/generate.mjs` writes — one field more or less and the seed stops
being loadable under the rules. `isAnchor` is in the list because the seed uses
it to mark its 14 real rows apart from the fictional ones.

`geohashPrefixes` is capped at 4 entries of 4–8 characters. Two precisions are
enough today (5 and 6); the cap exists so a document cannot be used to smuggle
in enough prefixes to match every cell on earth, which would turn the
`array-contains` prefilter into a collection scan.

`rating` is 0–5 and `beds` is 0–100000. Both are advisory. A hospital with
`rating: 0` is not thereby a bad hospital; the app treats a missing or zero
rating as "unknown" and does not rank on it.

### `users/{userId}`

Owner-only, including reads. `emergencyContacts` is capped at ten entries
because an unbounded array is a write-amplification primitive *and* a spam list
for whoever the user points it at.

Owner-initiated `delete` is allowed, and the rules file argues for it at the
point of decision: a driver who deletes their own history loses the evidence
that a crash happened, but "we kept your location because we might need it" is
not an answer to a person who wants their location data gone.

## The grant is not a notification

The single most important thing to understand about this schema, and the thing
most likely to be misread by a future UI:

```
  driver picks a hospital from a list  ──►  grants/{hospitalId} row exists
                                              │
                                              ▼
                            NOTHING IS SENT. NO ONE IS PAGED.
```

A grant records that a record was made visible. It is not a delivery receipt,
there is no acceptance workflow, and no hospital integration exists. Both
functions return an explicit `notice` string saying so, and §20 of the project
plan requires the UI to say it too. A UI that renders a grant as "Hospital
notified" would be the most damaging single bug in this project.

## Rules summary

| Path | Read | Write |
| --- | --- | --- |
| `users/{userId}` | owner | owner, with `createdAt`/`updatedAt` validation and a 10-contact cap |
| `accidents/{id}` | owner | owner, with the §18 transition graph and immutable measurements |
| `accidents/{id}/grants/{gid}` | owner or `gid` | owner creates/deletes; never updates |
| `accidents/{id}/attachments/{f}` | owner | owner, ≤5 MiB, image types only |
| `hospitals/{id}` | **public** | `admin == true` custom claim |
| everything else | denied | denied |

There is no `match /{document=**}` catch-all with a permissive rule, so a
collection added in future is denied until someone writes its rule on purpose.
For emergency PII that is the correct default.

## Writing path, and what bypasses the rules

| Writer | Bypasses rules? | Notes |
| --- | --- | --- |
| Cloud Functions (Admin SDK) | **Yes** | `dispatchAccident` writes accidents and grants. The rules never see these writes, which is why the function re-implements the ownership and transition checks in TypeScript (`isLegalTransition`, the `owner !== uid` test). |
| Seed import (Admin SDK) | **Yes** | `backend/seed/` |
| App client | No | Rules apply. Currently no client writes exist. |

Where a check exists in both the rules and the function, that is intentional
duplication: the rules protect against a compromised client, and the function's
copy protects against a future Admin-SDK caller that skips the rules entirely.

## Open items

- **The rules are unverified.** There is no rules test suite in this repository.
  `backend/README.md` lists the fourteen cases to write first. This is the
  highest-value gap in the project.
- `notifications` is not a collection and no delivery is attempted, so there is
  no `notifiedContactIds` writer. The field is validated on read/write so a
  future feature cannot inject unbounded junk into it.
- `attachments` are validated by the rules but no app code uploads one.
