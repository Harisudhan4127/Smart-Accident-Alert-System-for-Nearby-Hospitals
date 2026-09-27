# 05 — Hospital search

The search answers one question: **which facilities are near this point?** It is
a directory lookup. No hospital is contacted, paged, or told anything — see
[§20 and §27 of the project plan](../PROJECT_PLAN.md) and
[09](09-security-and-privacy.md).

## Two stages, and the second one is not optional

```
  lat, lon, radiusM
        │
        ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ STAGE 1 — geohash prefilter (Firestore, indexed)            │
  │                                                             │
  │   pass 1  geohashPrefixes array-contains <prefix6>           │
  │           hasEmergency == true                    → index 1  │
  │   pass 2  geohashPrefixes array-contains <prefix5>           │
  │           hasEmergency == true                    → index 1  │
  │   pass 3  geohashPrefixes array-contains <prefix5>           │
  │           type == <requested>                      → index 2  │
  │                                                             │
  │   ≤ 200 candidate documents, deduplicated by document id     │
  └─────────────────────────────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ STAGE 2 — precise haversine pass (in the function)          │
  │                                                             │
  │   for each candidate:                                       │
  │     metres = haversine(lat, lon, h.lat, h.lon)              │
  │     if metres > radiusM: drop                               │
  │   sort ascending by distanceM, slice to limit               │
  └─────────────────────────────────────────────────────────────┘
```

### Why two stages

Firestore cannot do a radius query, and geohash is the standard workaround: a
cell is a cheap indexable key, and a query on it is one indexed read. The
catch is that **geohash cells are not square**, and the cell containing a point
is not a box. Precision 6 is roughly 1.2 km × 0.6 km; the point may be in the
cell while the hospital is at the far edge of it, and vice versa.

So the prefilter is a *superset*. Stage 2 is what actually decides membership
and distance. Returning the prefilter directly would hand back hospitals up to
~5 km outside the requested radius, which on a 2 km search is a wrong answer,
not a rough one.

The prefix-6 pass is the tight one (~1.2 km cells). The prefix-5 pass widens to
~4.9 km cells for the case that matters most — a stretch of road or a rural
area where the tight cell is empty. The third pass exists only when the caller
passed `?type=`, and it uses the `type` index instead of `hasEmergency`; see
`backend/firestore.indexes.md` for why those are two indexes rather than one
three-field index.

### Bounds

| Bound | Value | Why |
| --- | --- | --- |
| Candidate documents read | 200 | Bounds the read cost and the loop time. Split across queries so the second pass gets the remainder of the budget rather than a second 200. |
| `radiusM` | 100 – 50 000 m, default 25 000 | Below 100 m is a rounding error; above 50 km nobody is driving. |
| `limit` | 1 – 50, default 10 | |
| `MAX_IMPACT_G` | 1000 g | Not search-related; see [04](04-firestore-schema.md). |

## Ordering: two different answers

This is the one genuinely confusing part, so it is worth being precise.

**The function sorts by distance only.** `nearby.sort((a, b) => a.distanceM - b.distanceM)`.
For a search screen under an emergency countdown, distance is the only ranking
that is unambiguously right: a 4.8-rated hospital 12 km away is worse than a
3.1-rated one 400 m away when someone is bleeding.

**The app's `Hospital.searchScore` scores capability.** In
`app/lib/domain/entities/hospital.dart`:

```dart
double searchScore(GeoPoint from) {
  const double emergencyBonus = 4000;
  const double normalisationM = 5000;
  final double metres = distanceFrom(from);
  final double proximity = 1 - (metres / normalisationM);
  final double proximityTerm = proximity <= 0 ? 0 : proximity;
  final double typeBonus = takesEmergencies ? emergencyBonus : 0;
  final double ratingBonus = (rating ?? 0) * 100;
  return proximityTerm * 1000 + typeBonus + ratingBonus;
}
```

Read that as: proximity dominates (0–1000), an emergency-capable facility gets
+4000, and rating is at most +500. So `searchScore` is a **capability filter
wearing a score's clothes**: any hospital that takes emergencies outranks any
hospital that does not, at any distance. `proximityTerm` is clamped to 0 beyond
5 km, so past 5 km the score is constant and only capability matters.

Neither is wrong. They answer different questions, and the app does not use
`searchScore` to order a list the server already ordered. If you wire a UI that
re-sorts the server's results by `searchScore`, the nearest hospital can be
demoted below a clinic 8 km away — which is defensible as a *filter* and
indefensible as a default in an emergency. If you want capability-based
grouping, group by it; do not silently reorder.

## The seed dataset

`backend/seed/hospitals.json` — 320 documents, regenerable byte-for-byte with
`node backend/seed/generate.mjs`.

| | |
| --- | --- |
| Total | 320 |
| Real anchors | 14 |
| Fictional | 306 |
| Emergency-capable | 229 |
| Types | 132 `MULTI_SPECIALITY`, 105 `EMERGENCY`, 74 `CLINIC`, 9 `OTHER` |
| Latitude range | 12.7523 – 13.2490 |
| Longitude range | 77.3659 – 77.8409 |
| Distinct precision-5 cells | 44 |
| Distinct precision-6 cells | 178 |

Distance from the city centre (Majestic, `12.9629, 77.5736`):

| Within | Hospitals |
| --- | --- |
| 2.5 km | 15 |
| 5 km | 74 |
| 10 km | 159 |
| 25 km | 221 |
| 50 km | 229 |

The 229 at 25 km is not all 320 on purpose: 91 rows sit outside the default
radius so that the `radiusM` parameter and the "no hospitals within range"
empty state are both exercisable.

### How it is generated, and why it is honest

- **14 real anchors** with real names, real addresses, and real coordinates.
  They are the rows a demo is most likely to be judged on, and a search that
  returns "Government General Hospital" for a Bangalore coordinate is the only
  evidence anyone will have that this works.
- **306 fictional rows**, clustered around six weighted real anchors (Majestic,
  Koramangala, Whitefield, Jayanagar, Yeshwanthpur, Yelahanka) with a seeded
  PRNG (`mulberry32`, seed `0x5aa52026`) so the output is byte-identical on
  every machine and every run. Their names are drawn from documented part lists
  (`<Prefix> <Core> <Suffix>`, e.g. "Sahyadri Cardiac Institute"), with a
  collision-avoiding retry loop and a numbered fallback.
- **Every one of the 320 phone numbers is synthetic**, including the anchors'.
  `fictionalPhone()` generates `080-2` + 7 digits; `anchorPhone()` generates
  `080-21xxxxx`–`080-22xxxxx`. The `080-2xxxx` range is not an allocated
  exchange, so a demo cannot dial a real party by accident. **This includes the
  real hospitals**: their names, addresses and coordinates are real, their phone
  numbers are not, and dialling one will not reach them. Publishing a real
  hospital's number in a prototype dataset whose other 306 rows are invented
  would be worse than a uniformly obviously-fake set.
- **`isAnchor: false` on every fictional row.** The seed file's own metadata
  says those rows must never be presented as real facilities, and the rules
  validate the field so it cannot be quietly dropped.
- **Self-validation on every run.** The generator re-derives each row's geohash
  prefixes from its own coordinates and asserts the hospital actually falls
  inside every cell it claims. A coordinate whose prefix does not contain it
  would be invisible to every search, and a seed that silently produced a few
  would look like a working dataset with holes in it.

Fictional rows are still geohash-valid, have plausible bed counts and ratings in
range, and are spread over 44 distinct cells. A demo that searches five
different places in the city sees five different results, which is the point.

### Loading it

```bash
cd backend
node seed/generate.mjs          # regenerate hospitals.json (idempotent)
firebase emulators:start --only firestore
firebase import --source seed/hospitals.json
```

`firebase import` uses the Admin SDK, so it bypasses the security rules. The
documents are still rule-valid — `validHospital`'s `hasOnly` list is exactly the
seed's key set — which is what makes the seed usable as a rules-test fixture.
- **The phone numbers do not work.** All 320 are synthetic `080-2xxxx` numbers,
  anchors included. A demo that dials one will not reach a hospital, and the UI
  must not invite a user to try.

## Caching and rate limits

| | |
| --- | --- |
| `Cache-Control` | `public, max-age=60, s-maxage=300` — 1 minute in the browser, 5 minutes at the CDN |
| Rate limit | In-memory token bucket, 30 requests refilled at 30/min, keyed on IP |
| Effect | Per instance. With `maxInstances: 10` the effective global ceiling is up to 300/min, and the bucket resets on cold start. |

The rate limiter exists to stop one runaway client turning an unauthenticated
endpoint into somebody else's Firestore bill. It is not a security control and
is not a DDoS mitigation — a real deployment needs App Check and a shared store
(Redis, or Firestore itself) for a global limit.

The cache is safe because a hospital list changes on the order of months. It
would not be safe for anything user-specific, which is why `dispatchAccident`
sets no cache header.

## CORS

`ALLOWED_ORIGINS` in `backend/functions/.env` is a comma-separated list. An
empty list means "reflect any origin", which is equivalent to `*` for a public
read endpoint and refuses credentialed requests — acceptable here, since
`nearbyHospitals` takes no credentials. For anything that reads user data, set
an explicit list.

---

## What this search does not do

- **It does not know which hospitals are actually open.** `hasEmergency` is a
  static dataset field, not a live feed. A hospital that closed its emergency
  department last month still says `hasEmergency: true`.
- **It does not route.** No travel time, no traffic, no ambulance ETA. Distance
  as the crow flies, which on a divided road can differ from driving distance by
  a factor of two.
- **It does not check capacity.** `beds` is a published number from a dataset
  generation ago, not an availability query.
- **It does not verify the data.** 306 of 320 rows are fictional, and nothing in
  the code marks that at the point of display. The app's job, per §20, is to
  present the list without implying verification.
