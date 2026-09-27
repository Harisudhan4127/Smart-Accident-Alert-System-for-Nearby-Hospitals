# Firestore indexes — what each one is for

`firestore.indexes.json` must stay machine-parseable, so it cannot carry the
explanation. This file is the other half of it: one entry per index, naming the
exact query that needs it. If you add a query, add its index here and in the
JSON in the same commit, and if you cannot say which query an index serves,
delete the index.

## The rule this file follows

**Only indexes that a query in this repository issues are deployed.** Every
composite index costs storage on every write and is one more thing that can drift
out of sync with the code, so an index for a feature that does not exist yet is
just a promise nobody has checked. Those are listed at the bottom as *not
deployed*, with the exact composite each will need when its feature ships.

At the time of writing, every query in the system is issued from
`backend/functions/src/index.ts`, as the Admin SDK:

| Location | Function | Indexes used |
| --- | --- | --- |
| `index.ts:340` | `nearbyHospitals` pass 1, prefix-6 cell | 1 |
| `index.ts:345` | `nearbyHospitals` pass 2, prefix-5 cell (wider) | 1 |
| `index.ts:352` | `nearbyHospitals` pass 3, `?type=` filter | 2 |
| `index.ts:528` | `dispatchAccident` return payload | 1 |

There is **no Firestore query in `app/lib/`** — the app reaches the backend
through `dispatchAccident` and `nearbyHospitals` and nothing else. The planned
history screens are listed under "Not deployed" below, and the index definitions
are written out so adding them is a copy-paste.

---

## 1. `hospitals`: `geohashPrefixes CONTAINS` + `hasEmergency ASC`

**Query** — `nearbyHospitals` main pass:

```ts
db.collection('hospitals')
  .where('geohashPrefixes', 'array-contains', prefix)
  .where('hasEmergency', '==', true)
  .limit(CANDIDATE_LIMIT)
```

**Why an index is required.** A single-field index cannot serve a query with an
array-contains filter *and* an equality filter on another field; Firestore
requires a composite index for the combination. The `hasEmergency` equality
filter is what keeps the result set small enough to hand to the precise haversine
pass below — without it, every clinic in the cell competes for the same
candidate limit.

**What `geohashPrefixes` is.** Each hospital document stores the geohash of its
own location at two precisions (5 and 6 characters, ~4.9 km and ~1.2 km cells).
A search computes the same prefixes for the accident location and asks for
`array-contains`, so the query returns a superset of the hospitals inside the
box. Geohash cells are not square, so this is a *prefilter*, not an exact box
test; that is why index 1 alone cannot answer the question and the haversine pass
is not optional.

Used by two of the four prefilter queries: the narrow precision-6 pass, and the
wider precision-5 pass that runs when the narrow cell is sparse. The width
changes, the filters do not, so the index does not.

## 2. `hospitals`: `geohashPrefixes CONTAINS` + `type ASC`

**Query** — `nearbyHospitals` when the caller passes `?type=MULTI_SPECIALTY`,
the "show me hospitals with a trauma unit" filter in §16's list screen.

**Why both this and index 1.** Firestore picks one index per query, and a query
cannot use an array-contains together with two equality filters without a
three-column composite — which in turn needs a different index again. Splitting
the two filters across two queries keeps the index set small and keeps each query
explainable. Do not merge them into one three-field index "to save an index": the
merged version serves fewer queries than the two it replaces.

---

## Not deployed, and why

These are the indexes the *designed* app needs. `app/lib/features/` and
`app/lib/widgets/` are empty, so nothing can issue these queries today and
deploying them would be configuring against code that does not exist.

| Query it would serve | Composite | Needed by |
| --- | --- | --- |
| History list, newest first, `startAfter` paging | `accidents`: `userId ASC`, `occurredAt DESC` | Planned history screen |
| History list filtered to one status | `accidents`: `userId ASC`, `status ASC`, `occurredAt DESC` | Planned history filter |
| Ranking a cell by quality when distance is a tie-break | `hospitals`: `hasEmergency ASC`, `type ASC`, `rating DESC` | Not currently needed — see below |

Note on the third row: an earlier revision of this file claimed the
`hasEmergency + type + rating` index served a fallback ranking inside
`nearbyHospitals`. It does not. The function's wider pass is a *broader geohash
cell* query using index 1, and the final ordering is computed in the function
after the haversine pass, because distance depends on the caller's coordinates
and cannot be indexed. The `rating DESC` composite has no query in this
repository and has been removed.

**Owner scoping for the future accident indexes.** `userId` goes first in the
composite *and* is constrained by `firestore.rules` to `request.auth.uid`. Either
alone would stop cross-user reads; both together mean a mistake in either one is
not exploitable on its own. Note that Firestore cannot use an index that does not
match a query's filters, equality order and sort order exactly, so the
three-field version will not serve the unfiltered query and vice versa — that,
not redundancy, is why both would be needed.

---

## Fields that deliberately have no index

| Field | Why not |
| --- | --- |
| `accidents.latitude` / `longitude` | Nothing queries accidents by location. Accident search would hand a stranger someone's crash site, which `firestore.rules` forbids (T1). |
| `hospitals.latitude` / `longitude` | The geohash prefixes are the indexable form of position. Two indexes on raw coordinates would invite someone to write a global range scan that reads the whole collection. |
| `users.phone` | Emergency-contact numbers must not be reachable by query even from a compromised client. |
| `accidents.status` alone | Every status query is owner-scoped, so a single-field index would only ever serve an unfiltered collection scan, which the rules deny (T3). |

## Adding an index safely

```bash
# Deploy to the emulator first and read the error: Firestore names the exact
# composite it wanted, so this is a copy-paste, not a guess.
cd backend
firebase emulators:start --only firestore
firebase deploy --only firestore:indexes --project <your-project>
```

Index changes are additive at deploy time and can be rolled back, but every
composite index costs storage and slows every write to the collection. If a
query can be expressed as a bounded read of a small collection, that is
usually cheaper than a composite index.
