# Backend — Firebase project

Firestore, Storage and two Cloud Functions for the Smart Accident Alert System.
This directory is deployable as-is; nothing here is a mock.

```
backend/
├── firebase.json              emulator + deploy configuration
├── firestore.rules            production security rules (deny by default)
├── firestore.indexes.json     composite indexes (machine-readable)
├── firestore.indexes.md       which query each index serves
├── storage.rules              crash-photo rules
├── functions/
│   ├── src/index.ts           dispatchAccident, nearbyHospitals, healthcheck
│   ├── package.json
│   └── tsconfig.json
└── seed/
    ├── generate.mjs           deterministic hospital generator
    └── hospitals.json         320 rows, generated
```

---

## What this backend does, and does not, do

It stores accident records and it returns a list of nearby hospitals.

**It does not notify a hospital.** There is no SMS gateway, no pager
integration, and no FCM topic for facilities. `dispatchAccident` writes a
document and a grant; `nearbyHospitals` reads a public directory. The grant
record in particular is easy to misread as a delivery receipt, so it is worth
being explicit: a grant means *a driver chose this facility from a list*. It
does not mean the facility was told, that anyone read the record, or that anyone
accepted the patient. `PROJECT_PLAN.md` §20 and §27 both call this out, and both
response payloads repeat it in a `notice` field so it cannot drift out of the
UI by accident.

Emergency notification in this prototype means the phone alerts the driver's own
emergency contacts. That is the app's job, on the user's device.

---

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Node | >= 20 | the functions runtime is `nodejs20` |
| Firebase CLI | latest | `npm i -g firebase-tools` |
| A Firebase project | — | Blaze plan, or the free Spark plan plus the emulator |

Spark plan is enough for the emulator and for Firestore/Storage. The HTTP
function needs Blaze to deploy, because Cloud Functions require a billing
account even at low traffic.

---

## Local development

```bash
# 1. Point the CLI at a real project. Never commit the result; the alias is
#    what firebase.json and the deploy commands read.
firebase use --add            # or: cp .firebaserc.example .firebaserc

# 2. Build the functions. `firebase deploy` and the emulator both do this via
#    the predeploy hook, but doing it by hand surfaces type errors faster.
cd functions && npm install && npm run build && cd ..

# 3. Start everything locally. Firestore and the functions run in-process; the
#    data is throwaway.
firebase emulators:start
```

The emulator UI prints its URL on start. `singleProjectMode` is on, so a stray
real credential cannot silently talk to a live project while you are testing.

### Loading the seed data

`hospitals.json` is a plain JSON document, not a Firestore export. The hospital
collection is public-read, so the cheapest correct load is the Admin SDK:

```bash
# One-off importer. Writes ~320 documents; batched at 400 per commit.
node -e '
  const fs = require("fs");
  const { initializeApp } = require("firebase-admin/app");
  const { getFirestore } = require("firebase-admin/firestore");
  initializeApp();
  const db = getFirestore();
  const data = JSON.parse(fs.readFileSync("seed/hospitals.json", "utf8"));
  let batch = db.batch(), n = 0;
  for (const h of data.hospitals) {
    const { isAnchor, ...fields } = h;
    batch.set(db.collection("hospitals").doc(), fields);
    if (++n % 400 === 0) { await batch.commit(); batch = db.batch(); }
  }
  await batch.commit();
  console.log("imported", n);
'
```

Run it with the emulator up (`FIRESTORE_EMULATOR_HOST=127.0.0.1:8080`) so a
mistake costs nothing.

`isAnchor` is dropped on import on purpose: it is provenance metadata about the
*seed file*, not a property of a hospital, and `firestore.rules` rejects any
field outside its allow-list. Keeping it in the document would mean loosening
the rules or failing the write.

### Regenerating the seed

```bash
node backend/seed/generate.mjs
```

Deterministic: the same seed produces the same bytes, so a diff of
`hospitals.json` shows only real changes. The generator validates its own output
before writing and exits non-zero on a bad row — a schema violation, a
duplicate name, a clinic marked emergency-capable, a stale geohash prefix, a
coordinate outside the seeded region, or fewer than 300 rows.

---

## Collections

| Collection | Access | Notes |
| --- | --- | --- |
| `users/{uid}` | owner only | §17 profile. Read is owner-only because it holds the phone numbers of the user *and* their family. |
| `accidents/{id}` | owner only | §17 record. `userId` is immutable; status changes must follow the §18 graph. |
| `accidents/{id}/grants/{hospitalId}` | owner, or the named hospital | Audit trail of who was let in. **Not a notification.** |
| `accidents/{id}/attachments/{file}` | owner only | Crash photos, < 5 MB, image MIME types only. |
| `hospitals/{id}` | public read, admin write | No personal data, so public read is safe; the write path is one custom claim. |

Document shapes are the ones the app already reads, not a parallel schema:
`Hospital.toMap()` in `app/lib/domain/entities/hospital.dart` is the authority
for hospitals, and `AccidentRecord` in
`app/lib/domain/entities/accident.dart` for accidents. `docs/05` has the field
list with types and ranges.

---

## Granting the hospital-admin claim

`firestore.rules` allows writes to `hospitals` only to a caller whose token
carries `admin: true`. It is a custom claim rather than a hard-coded address
because claims are set server-side, can be revoked, and do not leak a
maintainer's email into every rule file.

```bash
# Promote a user. Firestore rule changes are not retroactive, so the token has
# to be refreshed afterwards: sign out and back in, or call getIdToken(true).
node -e '
  const { initializeApp } = require("firebase-admin/app");
  const { getAuth } = require("firebase-admin/auth");
  initializeApp();
  getAuth().setCustomUserClaims("<uid>", { admin: true })
    .then(() => console.log("granted; user must refresh their token"));
'

# Revoke. Removing every claim, not just admin, so a stale admin cannot persist.
node -e '
  const { initializeApp } = require("firebase-admin/app");
  const { getAuth } = require("firebase-admin/auth");
  initializeApp();
  getAuth().setCustomUserClaims("<uid>", null).then(() => console.log("revoked"));
'
```

---

## Cloud Functions

### `dispatchAccident` — callable v2, `asia-south1`

```ts
const dispatch = httpsCallable(getFunctions(app, 'asia-south1'), 'dispatchAccident');
await dispatch({
  accidentId: 'client-generated-uuid',
  location: { latitude: 12.9716, longitude: 77.5946, accuracyM: 8 },
  impactValue: 4.82,
  status: 'CONFIRMED',
  deviceId: 'SAAS-A1B2C3D4',
  occurredAt: Date.now(),
  hospitalId: 'optional-choice-from-the-list',
});
```

Requires Firebase Auth. What it does:

- Validates every field (finite numbers, ranges, the §18 status set, a
  `accidentId` restricted to `[A-Za-z0-9_-]` so it can never be used as a path
  component).
- Takes `userId` from `request.auth`, never from the body.
- Writes `createdAt`, `updatedAt` and `dispatchedAt` as
  `FieldValue.serverTimestamp()`. A client cannot backdate an accident to hide
  it.
- Refuses a status transition the §18 graph does not allow, and refuses to
  touch a record owned by somebody else.
- Writes one grant when a hospital was chosen, with the reason fixed by the
  server.
- Returns the nearby hospitals, so the app needs one authenticated round trip
  instead of two.

### `nearbyHospitals` — HTTP, no auth

```
GET /nearbyHospitals?lat=12.9716&lon=77.5946&radiusM=25000&limit=10&type=MULTI_SPECIALTY
```

Public, because §16's list has to work before sign-in. What makes that
acceptable:

- Only the six public hospital fields are returned. No owner, no accident, no
  contact.
- Rate limited before any Firestore read.
- Bounded twice: `CANDIDATE_LIMIT` (200) documents read, `limit` (max 50)
  returned.
- Cached 5 minutes at the CDN, 1 minute in the browser.

The search itself is a two-stage funnel, and the second stage is not optional:

1. **Geohash prefilter.** Hospitals store their geohash at 5 and 6 characters
   (~4.9 km and ~1.2 km cells). The query is `array-contains` on that field,
   which is one composite index and one read. Geohash cells are not square, so
   the result is a *superset* of the box.
2. **Precise haversine pass.** Computed here, over the candidates, against the
   caller's actual coordinates. This is what decides membership and distance.

Skipping stage 2 and returning the prefilter would hand back hospitals up to
~5 km outside the requested radius, which on a 2 km search is a wrong answer,
not a rough one.

### Rate limiting

`nearbyHospitals` uses an in-memory token bucket: 30 requests, refilled at 30
per minute, keyed on the caller's IP.

It is per instance, not global. `maxInstances: 10` means the effective global
limit is up to 300 requests per minute, and the bucket resets on cold start. It
bounds one runaway client on one instance, which is what stops an open
unauthenticated endpoint from becoming someone else's Firestore bill. It is not
a security control.

For anything beyond a prototype, replace it with:

- **App Check** — verifies the calling app instance, so the endpoint can be
  closed to anything that is not the app.
- **A shared store** — Firestore or Redis, so the limit is global.

### Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `ALLOWED_ORIGINS` | `''` | Comma-separated CORS allow-list. Empty means "reflect the request origin", which is equivalent to `*` with credentials refused. Set it to your real web origins. |

```bash
# Stored in Secret Manager; do not put a live origin in a committed file.
firebase functions:secrets:set ALLOWED_ORIGINS   # not needed — this is a plain param
firebase functions:config                        # or use .env.<project> in functions/
```

For a plain string parameter, `.env.<project-id>` in `functions/` is the usual
route; see `functions/.env.example`.

---

## Deploying

```bash
# Rules and indexes first. A rules deploy is independent of a function deploy,
#   and shipping the function before the rules would leave a window where the
#   function can write something the rules then reject.
firebase deploy --only firestore:rules,firestore:indexes
firebase deploy --only storage
firebase deploy --only functions
```

Then load the seed (§ *Loading the seed data*), and check:

```bash
curl -s "https://asia-south1-<project>.cloudfunctions.net/healthcheck"
curl -s "https://asia-south1-<project>.cloudfunctions.net/nearbyHospitals?lat=12.9716&lon=77.5946&radiusM=5000&limit=3"
```

The second call must return a `notice` field saying no hospital has been
notified. If it does not, you are running an older deploy.

---

## Testing the rules

Rules bugs are silent, and the emulator is the only place they show up without
production data.

```bash
firebase emulators:exec --only firestore "npm run test:rules"
```

`firestore.rules` ships without a rules test suite in this repository; the
checks worth writing first, in order of risk, are:

| # | Scenario | Expected |
| --- | --- | --- |
| 1 | User A reads user B's profile | denied |
| 2 | Unauthenticated `list` on `users` | denied |
| 3 | User A creates an accident with `userId` = user B | denied |
| 4 | User A changes `userId` on their own accident | denied |
| 5 | User A moves their accident `DETECTED → ALERT_SENT` | denied |
| 6 | Client writes `status: 'UNKNOWN'` | denied |
| 7 | Client writes `latitude: 999` | denied |
| 8 | Signed-in user creates a hospital | denied |
| 9 | Hospital admin creates a valid hospital | allowed |
| 10 | User A creates a grant on their own accident | allowed |
| 11 | User A creates a grant on user B's accident | denied |
| 12 | Any write to an unlisted collection | denied |
| 13 | Storage read of another user's attachment | denied |
| 14 | Storage write of a 6 MB file, or `text/html` | denied |

Until that suite exists, treat the rules as unverified and re-read them before
every deploy. The threat model at the top of `firestore.rules` says what each
rule is for; if you cannot map a new rule to a `T` number, do not add it.

---

## Cost and limits

Worth knowing before a demo with real traffic:

| Thing | Limit that will bite |
| --- | --- |
| `nearbyHospitals` | 2 Firestore reads per request, plus 1–3 for the type filter. A CDN miss is a billed read. |
| `dispatchAccident` | 1 read to check ownership, 1 write batch (accident + grant), 1 search read. |
| `maxInstances: 10` | Caps both cost and cold-start pain. Above that, requests queue and users wait. |
| Firestore free tier | 50k reads/day, 20k writes/day. The seed import of 320 writes is negligible. |
| Cold start | A Node 20 function cold start is typically 300 ms–1 s. `dispatchAccident` sits on the confirm path, so this is felt. Move it off the critical path if that matters. |

---

## Related

- `docs/04-firestore-schema.md` — every field, type and range
- `docs/05-hospital-search.md` — the geohash funnel, and why it is two stages
- `docs/09-security.md` — the threat model, App Check, and what the rules cannot do
- `docs/13-troubleshooting.md` — permission-denied, index-missing, CORS
