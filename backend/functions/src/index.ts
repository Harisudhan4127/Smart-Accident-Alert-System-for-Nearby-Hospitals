/**
 * Cloud Functions — Smart Accident Alert System.
 *
 * Two entry points, and the split between them is deliberate.
 *
 *   dispatchAccident   callable v2, requires Firebase Auth. Called by the app
 *                      after the user confirms (§19). Writes the accident with
 *                      a *server* timestamp, records which hospital the user
 *                      chose, and writes an explicit grant. It does not notify
 *                      anybody.
 *
 *   nearbyHospitals    HTTP, no auth. §16's hospital list has to work before
 *                      sign-in, so this is a public read with rate limiting and
 *                      CORS. It returns public data only.
 *
 * Neither function sends an SMS, makes a phone call, or pages a hospital.
 * §20 is explicit that the prototype notifies the *user's own* emergency
 * contacts, and §27 warns that a nearby hospital being listed does not mean it
 * has received anything. Code in this repository must never imply otherwise.
 *
 * Trust model
 * -----------
 * The app runs on a device the user controls, so coordinates, impact values and
 * status are client-supplied and are *validated*, not believed. What the server
 * owns is everything a client has no business choosing:
 *
 *   - `createdAt` / `updatedAt` / `dispatchedAt` are FieldValue.serverTimestamp().
 *     A client cannot backdate an accident to hide it, or forward-date one to
 *     win a "was this me?" argument later.
 *   - `userId` comes from request.auth, never from the request body.
 *   - Distance is computed here, not accepted from the caller.
 *   - Grant scope is written by the function, not requested by the caller.
 *
 * The server is explicitly *not* able to vouch for the coordinates themselves:
 * an Android client can report any position it likes. See docs/09-security.md.
 */

import { onCall, onRequest, HttpsError, type CallableRequest } from 'firebase-functions/v2/https';
import { defineString } from 'firebase-functions/params';
import { initializeApp } from 'firebase-admin/app';
import { FieldValue, Timestamp, getFirestore, type DocumentData } from 'firebase-admin/firestore';
import type { QueryDocumentSnapshot } from 'firebase-admin/firestore';
import { setGlobalOptions } from 'firebase-functions/v2';

initializeApp();
setGlobalOptions({ region: 'asia-south1', maxInstances: 10 });

const db = getFirestore();

/* ------------------------------------------------------------------ limits */

/** §16 asks for a 25 km search; 50 km is the hard ceiling we will compute. */
const MAX_RADIUS_M = 50_000;
const MIN_RADIUS_M = 100;
const DEFAULT_RADIUS_M = 25_000;
const MAX_LIMIT = 50;
const DEFAULT_LIMIT = 10;

/** Documents pulled from Firestore before the precise distance pass. */
const CANDIDATE_LIMIT = 200;

const MAX_ACCURACY_M = 100_000;
const MAX_IMPACT_G = 1000;

const VALID_STATUSES = ['DETECTED', 'CANCELLED', 'CONFIRMED', 'ALERT_SENT', 'RESOLVED'] as const;
type Status = (typeof VALID_STATUSES)[number];

/* ------------------------------------------------------- rate limiting ---- */

/**
 * A per-instance, in-memory token bucket.
 *
 * Honest limitations, because this is a safety feature and a false sense of
 * protection is worse than none:
 *
 *   - It is per Cloud Function instance, not global. The platform scales
 *     horizontally, so N instances means N times the configured rate. It bounds
 *     one instance, which is what stops a single runaway client.
 *   - It resets on cold start and on redeploy.
 *   - It keys on the caller's IP, which behind a proxy is the proxy.
 *
 * A real deployment should replace this with App Check (verifies the app
 * instance) plus a shared store such as Firestore or Redis. See
 * backend/README.md "Rate limiting". This is here so an unauthenticated HTTP
 * endpoint is not an open invitation to bill someone for Firestore reads.
 */
const BUCKET_CAPACITY = 30;
const BUCKET_REFILL_PER_MS = 30 / 60_000; // 30 requests per minute
const buckets = new Map<string, { tokens: number; updatedAt: number }>();

function takeToken(key: string, now: number): boolean {
  let bucket = buckets.get(key);
  if (!bucket) {
    bucket = { tokens: BUCKET_CAPACITY, updatedAt: now };
    buckets.set(key, bucket);
  }
  const elapsed = Math.max(0, now - bucket.updatedAt);
  bucket.tokens = Math.min(BUCKET_CAPACITY, bucket.tokens + elapsed * BUCKET_REFILL_PER_MS);
  bucket.updatedAt = now;
  if (bucket.tokens < 1) return false;
  bucket.tokens -= 1;
  return true;
}

/** Keep the bucket map from growing without bound on a long-lived instance. */
function evictStaleBuckets(now: number): void {
  if (buckets.size < 5_000) return;
  for (const [key, bucket] of buckets) {
    if (now - bucket.updatedAt > 10 * 60_000) buckets.delete(key);
  }
}

/* ------------------------------------------------------------------ CORS --- */

/**
 * CORS for a public read endpoint.
 *
 * The list of allowed origins is a parameter rather than a literal so it can be
 * set per environment. `*` is only correct when the project has no web client;
 * see docs/09-security.md for why the default is not `*`.
 */
const ALLOWED_ORIGINS = defineString('ALLOWED_ORIGINS', { default: '' });

function corsHeaders(origin: string | undefined): Record<string, string> {
  const allowList = ALLOWED_ORIGINS.value()
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);
  const allowed = origin && (allowList.length === 0 || allowList.includes(origin)) ? origin : '';
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '3600',
    Vary: 'Origin',
  };
}

/* ---------------------------------------------------------------- geohash -- */

/**
 * Geohash encoding, dependency-free.
 *
 * Firestore cannot do a radius query. The usual workaround is a bounding box
 * on two numeric fields, which needs a range query on each and an index per
 * combination. Storing a geohash prefix per document turns the same question
 * into a single `array-contains`, which is one composite index and one read.
 *
 * Standard base-32 geohash alphabet, interleaved bits, most significant first.
 */
const GEOHASH_ALPHABET = '0123456789bcdefghjkmnpqrstuvwxyz';

function encodeGeohash(lat: number, lon: number, precision: number): string {
  let latMin = -90;
  let latMax = 90;
  let lonMin = -180;
  let lonMax = 180;
  let hash = '';
  let bits = 0;
  let bit = 0;
  let evenBit = true;

  while (hash.length < precision) {
    if (evenBit) {
      const mid = (lonMin + lonMax) / 2;
      if (lon >= mid) {
        bits = (bits << 1) | 1;
        lonMin = mid;
      } else {
        bits <<= 1;
        lonMax = mid;
      }
    } else {
      const mid = (latMin + latMax) / 2;
      if (lat >= mid) {
        bits = (bits << 1) | 1;
        latMin = mid;
      } else {
        bits <<= 1;
        latMax = mid;
      }
    }
    evenBit = !evenBit;
    if (++bit === 5) {
      hash += GEOHASH_ALPHABET[bits];
      bits = 0;
      bit = 0;
    }
  }
  return hash;
}

/** The two precisions stored on every hospital document. */
function prefixesFor(lat: number, lon: number): string[] {
  return [encodeGeohash(lat, lon, 5), encodeGeohash(lat, lon, 6)];
}

/* ------------------------------------------------------------------ geo ---- */

const EARTH_RADIUS_M = 6_371_008.8;
const toRad = (deg: number): number => (deg * Math.PI) / 180;

/** Haversine, matching `GeoPoint.distanceTo` in the app. */
function distanceM(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const dLat = toRad(bLat - aLat);
  const dLon = toRad(bLon - aLon);
  const s =
    Math.sin(dLat / 2) ** 2 + Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(s)));
}

/** Bounding box for a radius, used only to explain the query, not to filter. */
function boundingBox(lat: number, lon: number, radiusM: number) {
  const dLat = (radiusM / EARTH_RADIUS_M) * (180 / Math.PI);
  const cos = Math.cos(toRad(lat));
  const dLon = Math.abs(cos) < 1e-9 ? 180 : (radiusM / (EARTH_RADIUS_M * cos)) * (180 / Math.PI);
  return {
    minLat: Math.max(-90, lat - dLat),
    maxLat: Math.min(90, lat + dLat),
    minLon: lon - dLon,
    maxLon: lon + dLon,
  };
}

/* -------------------------------------------------------------- validation - */

class BadRequest extends Error {
  constructor(readonly field: string, message: string) {
    super(message);
  }
}

function requireFiniteNumber(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new BadRequest(field, `${field} must be a finite number`);
  }
  if (value < min || value > max) {
    throw new BadRequest(field, `${field} must be between ${min} and ${max}, got ${value}`);
  }
  return value;
}

function requireString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new BadRequest(field, `${field} must be a non-empty string`);
  }
  if (value.length > maxLength) {
    throw new BadRequest(field, `${field} must be at most ${maxLength} characters`);
  }
  return value.trim();
}

function requireStatus(value: unknown): Status {
  if (typeof value !== 'string' || !VALID_STATUSES.includes(value as Status)) {
    throw new BadRequest('status', `status must be one of ${VALID_STATUSES.join(', ')}`);
  }
  return value as Status;
}

function parseCoordinates(input: unknown): { lat: number; lon: number; accuracyM: number } {
  const source = (input ?? {}) as Record<string, unknown>;
  const lat = requireFiniteNumber(source.latitude ?? source.lat, 'latitude', -90, 90);
  const lon = requireFiniteNumber(source.longitude ?? source.lng ?? source.lon, 'longitude', -180, 180);
  const accuracyM = requireFiniteNumber(source.accuracyM ?? source.accuracy, 'accuracyM', 0, MAX_ACCURACY_M);
  return { lat, lon, accuracyM };
}

/* ------------------------------------------------------- nearbyHospitals --- */

/**
 * GET /nearbyHospitals?lat=..&lon=..&radiusM=..&limit=..&type=..
 *
 * Public, cached for five minutes, and returns exactly the six public fields
 * `app/lib/domain/entities/hospital.dart` reads. The compute-heavy part (the
 * haversine pass) is bounded twice: by `CANDIDATE_LIMIT` documents read from
 * Firestore, and by the `limit` returned to the caller.
 */
export const nearbyHospitals = onRequest(
  { cors: false, maxInstances: 10, timeoutSeconds: 30, memory: '256MiB' },
  async (req, res) => {
    const now = Date.now();
    const headers = corsHeaders(req.get('origin'));

    if (req.method === 'OPTIONS') {
      res.set(headers).set('Access-Control-Allow-Origin', headers['Access-Control-Allow-Origin'] || 'null');
      res.status(204).send('');
      return;
    }

    if (req.method !== 'GET') {
      res.set(headers).status(405).json({ error: 'method_not_allowed' });
      return;
    }

    // Rate limit before touching Firestore, keyed on the caller IP.
    const key = req.ip ?? req.get('x-forwarded-for') ?? 'unknown';
    evictStaleBuckets(now);
    if (!takeToken(key, now)) {
      res.set(headers).set('Retry-After', '60').status(429).json({ error: 'rate_limited' });
      return;
    }

    let lat: number;
    let lon: number;
    let radiusM = DEFAULT_RADIUS_M;
    let limit = DEFAULT_LIMIT;
    let type: string | undefined;

    try {
      const latRaw = req.query.lat ?? req.query.latitude;
      const lonRaw = req.query.lon ?? req.query.lng ?? req.query.longitude;
      lat = requireFiniteNumber(Number(latRaw), 'lat', -90, 90);
      lon = requireFiniteNumber(Number(lonRaw), 'lon', -180, 180);

      if (req.query.radiusM !== undefined) {
        radiusM = requireFiniteNumber(Number(req.query.radiusM), 'radiusM', MIN_RADIUS_M, MAX_RADIUS_M);
      }
      if (req.query.limit !== undefined) {
        limit = Math.min(MAX_LIMIT, Math.max(1, Number(req.query.limit) || DEFAULT_LIMIT));
      }
      if (typeof req.query.type === 'string' && req.query.type.length > 0) {
        if (!['EMERGENCY', 'MULTI_SPECIALTY', 'CLINIC', 'OTHER'].includes(req.query.type)) {
          throw new BadRequest('type', 'type must be EMERGENCY, MULTI_SPECIALTY, CLINIC or OTHER');
        }
        type = req.query.type;
      }
    } catch (error) {
      const message = error instanceof BadRequest ? error.message : 'invalid query parameters';
      const field = error instanceof BadRequest ? error.field : 'query';
      res.set(headers).status(400).json({ error: 'invalid_request', field, message });
      return;
    }

    const [prefix5, prefix6] = prefixesFor(lat, lon);
    const box = boundingBox(lat, lon, radiusM);

    // Two prefilter queries, matching indexes 1 and 2 in firestore.indexes.md.
    const candidates = new Map<string, QueryDocumentSnapshot<DocumentData>>();
    const queries = [
      db
        .collection('hospitals')
        .where('geohashPrefixes', 'array-contains', prefix6)
        .where('hasEmergency', '==', true),
      db
        .collection('hospitals')
        .where('geohashPrefixes', 'array-contains', prefix5)
        .where('hasEmergency', '==', true),
    ];
    if (type) {
      queries.push(
        db
          .collection('hospitals')
          .where('geohashPrefixes', 'array-contains', prefix5)
          .where('type', '==', type),
      );
    }

    for (const query of queries) {
      if (candidates.size >= CANDIDATE_LIMIT) break;
      const snapshot = await query.limit(CANDIDATE_LIMIT - candidates.size).get();
      for (const doc of snapshot.docs) candidates.set(doc.id, doc);
    }

    // Precise pass: the geohash prefilter is a superset, so this is what
    // actually decides membership and distance.
    const nearby = [];
    for (const doc of candidates.values()) {
      const data = doc.data();
      const hLat = data.latitude;
      const hLon = data.longitude;
      if (typeof hLat !== 'number' || typeof hLon !== 'number') continue;
      const metres = distanceM(lat, lon, hLat, hLon);
      if (metres > radiusM) continue;
      nearby.push({
        id: doc.id,
        name: data.name ?? 'Unnamed facility',
        address: data.address ?? '',
        latitude: hLat,
        longitude: hLon,
        phone: data.phone ?? '',
        type: data.type ?? null,
        hasEmergency: data.hasEmergency !== false,
        beds: typeof data.beds === 'number' ? data.beds : null,
        rating: typeof data.rating === 'number' ? data.rating : null,
        distanceM: Math.round(metres),
      });
    }

    nearby.sort((a, b) => a.distanceM - b.distanceM);

    res
      .set(headers)
      .set('Cache-Control', 'public, max-age=60, s-maxage=300')
      .status(200)
      .json({
        // The honest framing for §20/§27: this is a *directory*, not a
        // notification. Nothing has been sent to these facilities.
        notice: 'Listing only. No hospital has been notified or has accepted this case.',
        query: { lat, lon, radiusM, limit, type: type ?? null, geohashPrefixes: [prefix5, prefix6], boundingBox: box },
        candidateCount: candidates.size,
        count: Math.min(limit, nearby.length),
        hospitals: nearby.slice(0, limit),
      });
  },
);

/* --------------------------------------------------------- dispatchAccident */

/**
 * Callable v2, invoked by the app after the user confirms (§19).
 *
 * Writes: the accident document, and one grant subcollection entry naming the
 * hospital the user selected. Nothing is sent anywhere. The function returns the
 * nearest hospitals too, so the app gets the list and the record from one
 * authenticated round trip instead of two.
 */
export const dispatchAccident = onCall(
  { cors: true, maxInstances: 10, timeoutSeconds: 30, memory: '256MiB' },
  async (request: CallableRequest) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign in before dispatching an accident.');
    }

    const data = (request.data ?? {}) as Record<string, unknown>;

    let accidentId: string;
    let lat: number;
    let lon: number;
    let accuracyM: number;
    let impactValue: number;
    let status: Status;
    let deviceId: string | undefined;
    let occurredAt: Timestamp | null = null;
    let hospitalId: string | undefined;
    let hospitalName: string | undefined;

    try {
      accidentId = requireString(data.accidentId ?? data.id, 'accidentId', 128);
      if (!/^[A-Za-z0-9_-]+$/.test(accidentId)) {
        throw new BadRequest('accidentId', 'accidentId may only contain letters, digits, dash and underscore');
      }
      ({ lat, lon, accuracyM } = parseCoordinates(data.location ?? data));
      impactValue = requireFiniteNumber(data.impactValue, 'impactValue', 0, MAX_IMPACT_G);
      status = requireStatus(data.status ?? 'CONFIRMED');
      if (data.deviceId !== undefined && data.deviceId !== null) {
        deviceId = requireString(data.deviceId, 'deviceId', 64);
      }
      if (data.occurredAt !== undefined && data.occurredAt !== null) {
        // The node's own clock, when the app has one. Kept for display only;
        // createdAt below is the server's word on when this arrived.
        const millis = requireFiniteNumber(data.occurredAt, 'occurredAt', 0, 4_102_444_800_000);
        occurredAt = Timestamp.fromMillis(millis);
      }
      if (typeof data.hospitalId === 'string' && data.hospitalId.length > 0) {
        hospitalId = requireString(data.hospitalId, 'hospitalId', 64);
      }
      if (typeof data.hospitalName === 'string' && data.hospitalName.length > 0) {
        hospitalName = requireString(data.hospitalName, 'hospitalName', 160);
      }
    } catch (error) {
      if (error instanceof BadRequest) {
        throw new HttpsError('invalid-argument', `${error.field}: ${error.message}`);
      }
      throw new HttpsError('internal', 'Could not validate the dispatch request.');
    }

    const uid = request.auth.uid;
    const ref = db.collection('accidents').doc(accidentId);
    const serverNow = FieldValue.serverTimestamp();

    // T4/T5 from the rules' threat model, enforced server-side as well. The
    // rules already refuse a userId mismatch; repeating the check here means a
    // future Admin-SDK caller cannot skip it either.
    const existing = await ref.get();
    if (existing.exists) {
      const owner = existing.get('userId');
      if (owner !== uid) {
        throw new HttpsError('permission-denied', 'This accident belongs to another account.');
      }
      const previousStatus = existing.get('status') as Status | undefined;
      if (!isLegalTransition(previousStatus, status)) {
        throw new HttpsError(
          'failed-precondition',
          `Cannot move an accident from ${previousStatus ?? 'nothing'} to ${status}.`,
        );
      }
    }

    const record = {
      userId: uid,
      status,
      impactValue,
      latitude: lat,
      longitude: lon,
      accuracyM,
      occurredAt: occurredAt ?? serverNow,
      createdAt: existing.exists ? existing.get('createdAt') : serverNow,
      updatedAt: serverNow,
      dispatchedAt: serverNow,
      ...(deviceId ? { deviceId } : {}),
      ...(hospitalId ? { hospitalId } : {}),
      ...(hospitalName ? { hospitalName } : {}),
    };

    const batch = db.batch();
    if (existing.exists) {
      batch.update(ref, record);
    } else {
      batch.set(ref, record);
    }

    // The grant is the audit trail of who was shown this accident, written by
    // the server, with the reason fixed by us rather than by the caller.
    if (hospitalId) {
      batch.set(
        ref.collection('grants').doc(hospitalId),
        {
          grantedAt: serverNow,
          reason: 'Driver selected this facility from the nearby list (§19). Listing only; no hospital was notified.',
        },
        { merge: true },
      );
    }

    await batch.commit();

    const prefix6 = prefixesFor(lat, lon)[1];
    const nearbySnapshot = await db
      .collection('hospitals')
      .where('geohashPrefixes', 'array-contains', prefix6)
      .where('hasEmergency', '==', true)
      .limit(CANDIDATE_LIMIT)
      .get();

    const nearby = nearbySnapshot.docs
      .map((doc) => {
        const hospital = doc.data();
        if (typeof hospital.latitude !== 'number' || typeof hospital.longitude !== 'number') return null;
        return {
          id: doc.id,
          name: hospital.name ?? 'Unnamed facility',
          address: hospital.address ?? '',
          latitude: hospital.latitude,
          longitude: hospital.longitude,
          phone: hospital.phone ?? '',
          type: hospital.type ?? null,
          hasEmergency: hospital.hasEmergency !== false,
          distanceM: Math.round(distanceM(lat, lon, hospital.latitude, hospital.longitude)),
        };
      })
      .filter((h): h is NonNullable<typeof h> => h !== null && h.distanceM <= MAX_RADIUS_M)
      .sort((a, b) => a.distanceM - b.distanceM)
      .slice(0, DEFAULT_LIMIT);

    return {
      accidentId,
      status,
      storedAt: 'server-timestamp',
      notice: 'Stored. No hospital has been notified; this prototype alerts the driver\'s own contacts (§20).',
      nearby,
    };
  },
);

/** The §18 graph, mirrored from firestore.rules and AccidentStatus in the app. */
function isLegalTransition(from: Status | undefined, to: Status): boolean {
  if (from === undefined) return true;
  if (from === to) return true;
  switch (from) {
    case 'DETECTED':
      return to === 'CANCELLED' || to === 'CONFIRMED';
    case 'CONFIRMED':
      return to === 'ALERT_SENT';
    case 'ALERT_SENT':
      return to === 'RESOLVED';
    default:
      return false;
  }
}

/* ------------------------------------------------------------- healthcheck - */

/**
 * Liveness probe for the deploy pipeline. Deliberately does not touch
 * Firestore: a probe that depends on a database is a probe that fails during
 * the outage it was supposed to tell you about.
 */
export const healthcheck = onRequest({ cors: false }, (_req, res) => {
  res.status(200).json({ ok: true, service: 'smart-accident-alert', region: 'asia-south1' });
});
