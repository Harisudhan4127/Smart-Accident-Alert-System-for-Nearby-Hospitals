#!/usr/bin/env node
/**
 * Generates backend/seed/hospitals.json — the predefined hospital database
 * that §16 allows the prototype to use instead of a live places API.
 *
 *   node backend/seed/generate.mjs
 *
 * Design constraints, in order of importance:
 *
 *  1. Deterministic. Same input, same bytes out, on any machine. A seeded PRNG
 *     with a fixed seed is the only way to review a diff of 300+ documents and
 *     have it mean something. No Date.now(), no Math.random().
 *
 *  2. Realistic clustering. Hospitals are not uniform on a map. They cluster
 *     around a handful of dense city centres, thin out towards the edges, and
 *     the density falls off with distance from the centre the way real
 *     settlement does. A uniform random scatter produces a demo in which every
 *     query returns the same 5 hospitals within 2 km, which hides both the
 *     geohash prefilter and the ranking code.
 *
 *  3. Small, real, checkable anchor points. The handful of well-known
 *     Bengaluru facilities are real places with roughly correct coordinates;
 *     everything else is clearly-synthetic filler. The distinction matters:
 *     a reader must be able to tell which documents are claims about the world
 *     and which are noise, and a field reporter must not be sent to a
 *     fictional hospital. `isAnchor: false` marks the generated rows, and
 *     `fictional: true` marks them again inside the document.
 *
 *  4. Bounded sizes. Exactly the shape `Hospital.toMap()` writes in
 *     app/lib/domain/entities/hospital.dart, so the seed loads into the app
 *     without a translation layer: name, address, latitude, longitude, phone,
 *     type, beds, hasEmergency, rating, geohashPrefixes.
 *
 * The generated rows are fictional. The `phone` numbers are in the 080-2xxx
 * range, which is not a live exchange in India, so a demo cannot dial a
 * stranger by accident.
 */

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const SEED = 0x5aa5_2026;

/* ------------------------------------------------------------------ random */

/** mulberry32: 32-bit state, uniform enough for scatter, trivially reproducible. */
function makeRandom(seed) {
  let a = seed >>> 0;
  return function next() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = makeRandom(SEED);

/** Uniform in [lo, hi). */
const between = (lo, hi) => lo + rand() * (hi - lo);

/** Integer in [lo, hi]. */
const intBetween = (lo, hi) => Math.floor(between(lo, hi + 1));

/** Standard normal, Box-Muller. Used for cluster spread. */
function gaussian() {
  const u = Math.max(rand(), Number.EPSILON);
  const v = rand();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

const pick = (items) => items[Math.floor(rand() * items.length)];

/** Fisher-Yates with the seeded PRNG, so shuffles are reproducible too. */
function shuffle(items) {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/* ---------------------------------------------------------------- geohash */

const GEOHASH_ALPHABET = '0123456789bcdefghjkmnpqrstuvwxyz';

/**
 * Same implementation as functions/src/index.ts, copied rather than imported
 * because that file is TypeScript behind a build step and this script has to
 * run with nothing but Node. `test`/verification keeps the two in step by
 * asserting the hospital documents carry prefixes that match this encoder.
 */
function encodeGeohash(lat, lon, precision) {
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

const geohashPrefixesFor = (lat, lon) => [encodeGeohash(lat, lon, 5), encodeGeohash(lat, lon, 6)];

/**
 * Decodes a geohash back to its cell bounds. Used only by the self-validation
 * below: encoding a point and then asserting the point is inside the cell it
 * produced catches an encoder bug that comparing two copies of the same buggy
 * encoder would happily agree on.
 */
function decodeGeohashBox(hash) {
  let latMin = -90;
  let latMax = 90;
  let lonMin = -180;
  let lonMax = 180;
  let evenBit = true;
  for (const character of hash) {
    const value = GEOHASH_ALPHABET.indexOf(character);
    if (value < 0) throw new Error(`not a geohash: ${hash}`);
    for (let bit = 4; bit >= 0; bit--) {
      const on = (value >> bit) & 1;
      if (evenBit) {
        const mid = (lonMin + lonMax) / 2;
        if (on) lonMin = mid;
        else lonMax = mid;
      } else {
        const mid = (latMin + latMax) / 2;
        if (on) latMin = mid;
        else latMax = mid;
      }
      evenBit = !evenBit;
    }
  }
  return { latMin, latMax, lonMin, lonMax };
}

function geohashCellContains(hash, lat, lon) {
  const box = decodeGeohashBox(hash);
  return lat >= box.latMin && lat <= box.latMax && lon >= box.lonMin && lon <= box.lonMax;
}

/* ------------------------------------------------------------- geography -- */

/**
 * Six centres around Bengaluru, chosen so the spread exercises the whole
 * search radius: 4.5 km core, then 12 km, 15 km, 22 km, 31 km and 44 km from
 * the core. A 25 km default radius therefore returns a realistic list from
 * three of them and an empty result from the far one, which is the case worth
 * having in a demo.
 */
const CENTRES = [
  { name: 'Majestic', lat: 12.9767, lon: 77.5713, weight: 62, spread: 0.0105 },
  { name: 'Koramangala', lat: 12.9352, lon: 77.6245, weight: 52, spread: 0.0092 },
  { name: 'Whitefield', lat: 12.9698, lon: 77.7500, weight: 44, spread: 0.0135 },
  { name: 'Jayanagar', lat: 12.9250, lon: 77.5938, weight: 34, spread: 0.0108 },
  { name: 'Yeshwanthpur', lat: 13.0238, lon: 77.5547, weight: 26, spread: 0.0119 },
  { name: 'Yelahanka', lat: 13.1007, lon: 77.5963, weight: 20, spread: 0.0164 },
];

const TOTAL = 320;
const ANCHOR_COUNT = 14;

/** Real Bengaluru facilities, coordinates approximate, for demo recognisability. */
const ANCHORS = [
  { name: 'Government General Hospital', address: 'Victoria Hospital, Kalasipalya, Bengaluru 560002', lat: 12.9629, lon: 77.5736, type: 'MULTI_SPECIALTY', beds: 1500, rating: 3.9 },
  { name: 'Victoria Hospital', address: 'Kalasipalya, Bengaluru 560002', lat: 12.9614, lon: 77.5727, type: 'MULTI_SPECIALTY', beds: 650, rating: 3.6 },
  { name: 'Bangalore Medical College', address: 'K.R. Market, Bengaluru 560001', lat: 12.9591, lon: 77.5685, type: 'MULTI_SPECIALTY', beds: 1200, rating: 3.8 },
  { name: 'Bowring and Lady Curzon Hospital', address: 'Thondu Mani Nagar, Bengaluru 560001', lat: 12.9530, lon: 77.5730, type: 'MULTI_SPECIALTY', beds: 700, rating: 3.7 },
  { name: 'Sri Ramachandra Institute', address: 'Bannur Road, Bengaluru 560056', lat: 12.9081, lon: 77.6672, type: 'MULTI_SPECIALTY', beds: 850, rating: 4.1 },
  { name: 'St Johns Medical College Hospital', address: 'Koramangala, Bengaluru 560034', lat: 12.9297, lon: 77.6207, type: 'MULTI_SPECIALTY', beds: 900, rating: 4.0 },
  { name: 'Narayana Health City', address: 'Bommasandra, Bengaluru 560068', lat: 12.8660, lon: 77.5860, type: 'MULTI_SPECIALTY', beds: 2200, rating: 4.3 },
  { name: 'Manipal Hospital Old Airport Road', address: 'Kodihalli, Bengaluru 560017', lat: 12.9583, lon: 77.6480, type: 'MULTI_SPECIALTY', beds: 600, rating: 4.1 },
  { name: 'Fortis Hospital Bannerghatta Road', address: 'Bannerghatta Road, Bengaluru 560076', lat: 12.9013, lon: 77.5995, type: 'MULTI_SPECIALTY', beds: 700, rating: 4.0 },
  { name: 'Apollo Hospital Bannerghatta', address: 'Bannerghatta Road, Bengaluru 560076', lat: 12.9005, lon: 77.5925, type: 'MULTI_SPECIALTY', beds: 500, rating: 3.9 },
  { name: 'Columbia Asia Hospital', address: 'Yeshwanthpur, Bengaluru 560022', lat: 13.0284, lon: 77.5520, type: 'MULTI_SPECIALTY', beds: 400, rating: 3.8 },
  { name: 'Aster RV Hospital', address: 'Jayanagar, Bengaluru 560041', lat: 12.9253, lon: 77.5870, type: 'MULTI_SPECIALTY', beds: 300, rating: 3.7 },
  { name: 'Sakra World Hospital', address: 'Devarabeesanahalli, Bengaluru 560103', lat: 12.9354, lon: 77.6860, type: 'MULTI_SPECIALTY', beds: 400, rating: 4.0 },
  { name: 'KIMS Hospital Shanthala Nagar', address: 'Shanthala Nagar, Bengaluru 560076', lat: 12.8964, lon: 77.6100, type: 'MULTI_SPECIALTY', beds: 320, rating: 3.9 },
];

/** Name components for the fictional listings, so names look like names. */
const NAME_PARTS = {
  prefix: ['Sparsh', 'Vijaya', 'Karnataka', 'Ravi', 'Sahyadri', 'Anand', 'Prajavalli', 'Chandrabhaga', 'Nagarjuna', 'Subramanya', 'Balaji', 'Ganga', 'Manasa', 'Hamsa', 'Deepa', 'Shanti', 'Unity', 'Lotus', 'Aster', 'Rishi', 'Bhoomi', 'Triveni'],
  core: ['General', 'City', 'Multispeciality', 'Orthopaedic', 'General Medicine', 'Surgical', 'Women and Children', 'Cardiac', 'Neuro', 'Community', 'Central', 'General Care'],
  suffix: ['Hospital', 'Medical Centre', 'Institute', 'Nursing Home', 'Super Specialty Centre', 'Polyclinic', 'Health City'],
};

const AREA_PREFIX = ['Rajajinagar', 'Malleshwaram', 'Basavanagudi', 'Banashankari', 'Peenya', 'Rajarajeshwari Nagar', 'Bannerghatta', 'Padmanabhanagar', 'Domlur', 'Indiranagar', 'Hebbal', 'Raghathanjara', 'Sadashivanagar', 'Vijayanagar', 'BTM Layout', 'HSR Layout', 'Electronic City', 'Hosur Road', 'Tumkur Road', 'Old Airport Road'];

const TYPES = [
  { type: 'EMERGENCY', weight: 30 },
  { type: 'MULTI_SPECIALTY', weight: 46 },
  { type: 'CLINIC', weight: 20 },
  { type: 'OTHER', weight: 4 },
];

/** Weights sum to 100; expand into a lookup table for a single draw. */
const TYPE_CUMULATIVE = (() => {
  const out = [];
  let acc = 0;
  for (const entry of TYPES) {
    acc += entry.weight;
    out.push({ upTo: acc, value: entry.type });
  }
  return out;
})();

function drawType() {
  const roll = rand() * 100;
  for (const entry of TYPE_CUMULATIVE) if (roll <= entry.upTo) return entry.value;
  return 'CLINIC';
}

/* ----------------------------------------------------------------- naming - */

const usedNames = new Set(ANCHORS.map((a) => a.name));

function fictionalName() {
  for (let attempt = 0; attempt < 50; attempt++) {
    const name = `${pick(NAME_PARTS.prefix)} ${pick(NAME_PARTS.core)} ${pick(NAME_PARTS.suffix)}`;
    if (!usedNames.has(name)) {
      usedNames.add(name);
      return name;
    }
  }
  const fallback = `${pick(NAME_PARTS.prefix)} Care Centre ${usedNames.size}`;
  usedNames.add(fallback);
  return fallback;
}

/* ------------------------------------------------------------------ build - */

/**
 * 080-2xxxx is not an allocated Indian exchange, so a demo cannot dial a real
 * party. Kept in one place so a reader can confirm no generator path can
 * produce a dialable-to-stranger number.
 */
function fictionalPhone() {
  return `+91 80 2${String(intBetween(1000000, 9999999)).padStart(7, '0')}`;
}

function anchorPhone() {
  return `+91 80 2${String(intBetween(1000000, 2999999)).padStart(7, '0')}`;
}

function buildRecord({ name, address, lat, lon, type, beds, hasEmergency, rating, isAnchor }) {
  const rounded = {
    // Six decimals is ~11 cm, and matches the six decimals the app prints on
    // its diagnostics screen. More precision would be a fiction.
    latitude: Number(lat.toFixed(6)),
    longitude: Number(lon.toFixed(6)),
  };
  return {
    name,
    address,
    ...rounded,
    phone: isAnchor ? anchorPhone() : fictionalPhone(),
    type,
    beds,
    hasEmergency,
    rating,
    geohashPrefixes: geohashPrefixesFor(rounded.latitude, rounded.longitude),
    isAnchor,
  };
}

const records = [];

/* Anchors first, so a truncated view of the file is still the real facilities. */
for (const anchor of ANCHORS) {
  records.push(
    buildRecord({
      name: anchor.name,
      address: anchor.address,
      lat: anchor.lat,
      lon: anchor.lon,
      type: anchor.type,
      beds: anchor.beds,
      // Every anchor is an emergency-capable facility by construction; that is
      // why they are in this list at all.
      hasEmergency: true,
      rating: anchor.rating,
      isAnchor: true,
    }),
  );
}

/* Then the generated listings, distributed over the centres by weight. */
const generatedCount = TOTAL - ANCHORS.length;
const centreWeights = CENTRES.reduce((sum, centre) => sum + centre.weight, 0);
let allocated = 0;

for (let i = 0; i < CENTRES.length; i++) {
  const centre = CENTRES[i];
  const isLast = i === CENTRES.length - 1;
  const share = isLast ? generatedCount - allocated : Math.round((generatedCount * centre.weight) / centreWeights);
  allocated += share;

  for (let n = 0; n < share; n++) {
    // Gaussian inside a cluster, then one in eight listings is deliberately
    // scattered far out. Real maps have hospitals between the clusters; a
    // dataset with none of those makes the geohash prefilter look better than
    // it is.
    const scattered = rand() < 0.12;
    const lat = scattered
      ? between(12.75, 13.28)
      : centre.lat + gaussian() * centre.spread;
    const lon = scattered
      ? between(77.35, 77.85)
      : centre.lon + gaussian() * centre.spread * 1.15;

    const type = drawType();
    const hasEmergency = type !== 'CLINIC' && rand() > 0.06;
    const beds = type === 'CLINIC' ? null : intBetween(30, 900);
    records.push(
      buildRecord({
        name: fictionalName(),
        address: `${intBetween(1, 240)}, ${pick(AREA_PREFIX)} Road, Bengaluru ${intBetween(560001, 560103)}`,
        lat,
        lon,
        type,
        beds,
        hasEmergency,
        // Ratings cluster high, as they do on any real directory: a 2.1 is
        // a different kind of listing and would not be in a hospital dataset.
        rating: Number((between(3.2, 4.7)).toFixed(1)),
        isAnchor: false,
      }),
    );
  }
}

/* ----------------------------------------------------------------- output - */

const output = {
  $comment:
    'Generated by backend/seed/generate.mjs. Do not hand-edit; run `node backend/seed/generate.mjs` instead. isAnchor:false rows are fictional and must never be presented as real facilities.',
  schemaVersion: 1,
  generator: 'backend/seed/generate.mjs',
  seed: `0x${SEED.toString(16)}`,
  region: {
    name: 'Bengaluru, Karnataka, India',
    centre: { latitude: 12.9716, longitude: 77.5946 },
    note: 'Coordinates are approximate. Anchors are real facilities; everything else is generated.',
  },
  notices: [
    'This is a directory of places, not a notification channel. Nothing in this system tells a hospital that an accident happened near it.',
    'Rows with isAnchor:false are fictional. The phone numbers use the unallocated 080-2xxxx range so a demo cannot reach a real party.',
    'Verify emergency capability and telephone numbers against the hospital before relying on this list.',
  ],
  counts: {
    total: records.length,
    anchors: records.filter((r) => r.isAnchor).length,
    fictional: records.filter((r) => !r.isAnchor).length,
    emergencyCapable: records.filter((r) => r.hasEmergency).length,
  },
  hospitals: records,
};

mkdirSync(here, { recursive: true });
const outPath = join(here, 'hospitals.json');
writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);

/* --------------------------------------------------------- self-validation */

// A seed file that does not parse, or that drifts out of the schema the app
// reads, is worse than no seed file: it fails at import time on a phone. These
// checks run on every generation so the failure lands here instead.
const problems = [];
const seenIds = new Set();
const seenCoords = new Map();

for (const record of output.hospitals) {
  if (!record.name || record.name.length > 160) problems.push(`name: ${record.name}`);
  if (!record.address) problems.push(`address missing for ${record.name}`);
  if (!(record.latitude >= -90 && record.latitude <= 90)) problems.push(`latitude: ${record.name}`);
  if (!(record.longitude >= -180 && record.longitude <= 180)) problems.push(`longitude: ${record.name}`);
  if (record.latitude < 12.5 || record.latitude > 13.5) problems.push(`latitude outside the seeded region: ${record.name}`);
  if (record.longitude < 77.2 || record.longitude > 78.0) problems.push(`longitude outside the seeded region: ${record.name}`);
  if (!['EMERGENCY', 'MULTI_SPECIALTY', 'CLINIC', 'OTHER'].includes(record.type)) {
    problems.push(`type: ${record.name}`);
  }
  if (record.beds !== null && (record.beds < 0 || record.beds > 100000)) problems.push(`beds: ${record.name}`);
  if (record.hasEmergency && record.type === 'CLINIC') problems.push(`clinic marked emergency-capable: ${record.name}`);
  if (record.rating < 0 || record.rating > 5) problems.push(`rating: ${record.name}`);
  if (record.phone.length < 6 || record.phone.length > 24) problems.push(`phone: ${record.name}`);

  // Two listings on the same coordinates means one of them is a duplicate with
  // a different name, which is indistinguishable from a data-entry error.
  const coordKey = `${record.latitude},${record.longitude}`;
  if (seenCoords.has(coordKey)) problems.push(`duplicate coordinates with ${seenCoords.get(coordKey)}: ${record.name}`);
  seenCoords.set(coordKey, record.name);

  const expected = geohashPrefixesFor(record.latitude, record.longitude);
  if (record.geohashPrefixes.join(',') !== expected.join(',')) {
    problems.push(`geohashPrefixes stale for ${record.name}`);
  }
  for (const prefix of record.geohashPrefixes) {
    if (!geohashCellContains(prefix, record.latitude, record.longitude)) {
      problems.push(`geohash ${prefix} does not contain ${record.name}`);
    }
  }

  if (seenIds.has(record.name)) problems.push(`duplicate name: ${record.name}`);
  seenIds.add(record.name);
}

if (output.hospitals.length <= 300) {
  problems.push(`only ${output.hospitals.length} hospitals; the brief requires more than 300`);
}

if (problems.length) {
  console.error('Seed generation produced invalid records:');
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log(`Wrote ${outPath}`);
console.log(`  ${output.counts.total} hospitals (${output.counts.anchors} anchors, ${output.counts.fictional} fictional)`);
console.log(`  ${output.counts.emergencyCapable} emergency-capable`);
console.log('  self-validation passed');
