# 09 — Security and privacy

This system handles **live location data** and the **phone numbers of the people
you would call in an emergency**. Both are sensitive. This is what the code
actually does about it.

- [Threat model](#threat-model)
- [Permissions](#permissions)
- [The Firebase security boundary](#the-firebase-security-boundary)
- [Location data](#location-data)
- [Emergency contacts](#emergency-contacts)
- [BLE security](#ble-security)
- [The honest limitations](#the-honest-limitations)

---

## Threat model

Four parties, and what each of them can reach:

| Party | Capability | Mitigation |
| --- | --- | --- |
| **Someone with the phone** | Physical access to everything, including the profile | Out of scope. Mitigated only by the OS lock screen. |
| **A stolen / cloned credential** | A valid Firestore auth token | Anonymous auth by default; rules are per-document. Revoking a Firebase session kills access immediately. |
| **A malicious client** | Arbitrary Firestore reads/writes with a valid token | This is what the security rules exist for. They are the *only* real boundary — the app's own checks are advisory. |
| **A passive network observer** | Sees TLS metadata | TLS for all traffic. The BLE link is **not** encrypted; see [BLE security](#ble-security). |

The important observation: **anything enforced only in the app is not
enforced.** The app checks the latitude is in range; the rules check it again,
because the app is the thing an attacker modifies.

---

## Permissions

Every permission the app requests, and why it cannot be avoided.

### Android

| Permission | Why | Consequence if refused |
| --- | --- | --- |
| `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` | Find and connect to the node (Android 12+ split these out of `BLUETOOTH`) | The app cannot function. Stated on the splash screen. |
| `ACCESS_FINE_LOCATION` | Required for BLE scanning **and** for the accident location | Both scanning and location are broken. |
| `ACCESS_COARSE_LOCATION` | Approximate location, if the user prefers it | Coarser fix; a city block is enough to find a hospital |
| `ACCESS_BACKGROUND_LOCATION` | Keep monitoring with the app backgrounded | Android kills the BLE connection after a few minutes. **Requested separately**, with an explanation, never bundled into the initial prompt. |
| `POST_NOTIFICATIONS` | The emergency alert (Android 13+) | The app still works, but **an alert may not reach the user if the app is closed.** This is called out in the UI, because it is the one refusal that can cause the system to fail silently. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Keep the BLE link alive while monitoring | Monitoring stops in the background |
| `INTERNET`, `ACCESS_NETWORK_STATE` | Firestore, and the offline banner | Fully offline; accidents still recorded locally |

`ACCESS_FINE_LOCATION` is required for BLE scanning on Android 10+ regardless of
whether the app ever stores a location. This surprises people, so the app says
so rather than letting a permission dialog appear unexplained.

### iOS

| Key | Why | Consequence if refused |
| --- | --- | --- |
| `NSLocationWhenInUseUsageDescription` | Accident location | Same as Android |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Background monitoring | iOS suspends the app; no alerts while backgrounded |
| `NSBluetoothAlwaysUsageDescription` | Find the node | Cannot pair |
| `UIBackgroundModes: bluetooth-central` | Keep the link alive | Monitoring stops when suspended |

Every iOS usage string is a required-attestation string: a vague one is grounds
for App Store rejection. The strings in `Info.plist` say specifically what the
data is for.

**No permission is requested at launch without a stated reason.** The splash
screen runs the checks in order and reports each outcome separately, so a
permission prompt always has visible context.

---

## The Firebase security boundary

`backend/firestore.rules`. Deny-by-default: anything not explicitly permitted is
refused.

```rules
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // ── users ────────────────────────────────────────────────────────────
    // Owner-only. There is deliberately NO `list` grant: a user must not be
    // able to enumerate who else uses the service, and `emergencyContacts`
    // inside these documents is another person's phone number.
    match /users/{userId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;

      // Field-level validation. A compromised client must not be able to write
      // a document that breaks every consumer.
      allow create, update: if request.resource.data.keys()
        .hasOnly(['name', 'phone', 'vehicleNumber', 'emergencyContacts'])
        && request.resource.data.name is string
        && request.resource.data.name.size() <= 100
        && request.resource.data.vehicleNumber is string
        && request.resource.data.vehicleNumber.size() <= 20
        && request.resource.data.emergencyContacts is list
        && request.resource.data.emergencyContacts.size() <= 20;
    }

    // ── accidents ────────────────────────────────────────────────────────
    match /accidents/{accidentId} {
      // The owner sees their own history.
      allow read: if request.auth != null && resource.data.userId == request.auth.uid;

      // Write is narrower than read: a user may *create* their own accident,
      // but may not rewrite an existing one. Without this, a client bug could
      // silently overwrite a `RESOLVED` incident with `DETECTED`.
      allow create: if request.auth != null
        && request.resource.data.userId == request.auth.uid
        && isValidAccident(request.resource.data);

      // Transitions are constrained to moving *forward* in the §18 state
      // machine, so a replayed or forged write cannot reopen a closed incident.
      allow update: if request.auth != null
        && resource.data.userId == request.auth.uid
        && request.resource.data.userId == resource.data.userId
        && validTransition(resource.data.status, request.resource.data.status)
        && isValidAccident(request.resource.data);

      // No delete. An accident record is a log; deleting it is not the owner's
      // to do unilaterally. A retention policy would delete server-side.

      // A responder is granted read on ONE accident, never on the history.
      // NOTE: being able to read an accident does NOT mean the hospital was
      // notified — see §16 and §27. There is no notification path today.
      allow get: if request.auth != null
        && (resource.data.userId == request.auth.uid
            || exists(/databases/$(database)/documents/responders/$(request.auth.uid))
               && resource.data.id in
                  get(/databases/$(database)/documents/responders/$(request.auth.uid)).data.incidentIds);

      function isValidAccident(d) {
        return d.latitude is number && d.latitude >= -90 && d.latitude <= 90
            && d.longitude is number && d.longitude >= -180 && d.longitude <= 180
            && d.accuracy is number && d.accuracy >= 0 && d.accuracy <= 100000
            && d.timestamp is timestamp
            && d.impactValue is number
            && d.status in ['DETECTED','CANCELLED','CONFIRMED','ALERT_SENT','RESOLVED']
            && d.deviceId is string;
      }

      // §18: DETECTED → {CANCELLED, CONFIRMED}, CONFIRMED → ALERT_SENT,
      // ALERT_SENT → RESOLVED, and every state may go to RESOLVED.
      function validTransition(from, to) {
        return (from == 'DETECTED'  && to in ['CANCELLED','CONFIRMED','RESOLVED'])
            || (from == 'CONFIRMED'  && to in ['ALERT_SENT','RESOLVED'])
            || (from == 'ALERT_SENT' && to == 'RESOLVED')
            || (from == 'RESOLVED'   && to == 'RESOLVED');
      }
    }

    // ── hospitals ────────────────────────────────────────────────────────
    // Public read: it is a public directory of public facilities.
    // Admin-only write: a compromised client must not be able to add a fake
    // hospital that a responder is then directed to.
    match /hospitals/{hospitalId} {
      allow read: if true;
      allow write: if request.auth != null
        && request.auth.token.admin == true;
    }

    // ── responders ───────────────────────────────────────────────────────
    match /responders/{uid} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```

Four things worth calling out:

1. **No public `list` on `users`.** Without this, any authenticated user could
   page through every account in the collection.
2. **`create` and `update` are separated.** An update cannot change `userId`, so
   an accident cannot be transferred to another account.
3. **Transitions are constrained server-side.** The §18 state machine is enforced
   in the rules, not just in `AccidentStatus.canTransitionTo` in the app. A
   replayed write cannot reopen a resolved incident.
4. **Coordinates are range-validated** so a malicious client cannot write
   `latitude: 1e308` and break every consumer.

### Anonymous auth

The app signs in anonymously. This is not "no auth" — it is a real, revocable
identity that the rules can check, and it collects no PII. Upgrading to an email
link later keeps the same `uid`, so no document migration is needed.

---

## Location data

**What is stored:** latitude, longitude, accuracy and a timestamp, per accident.
Never a continuous trail. The app does not track the vehicle between accidents.

**Where:** `accidents/{accidentId}`, owner-readable only.

**Retention:** not implemented. An accident record is a log and there is no
`delete` grant. A production deployment needs a retention policy (e.g. 24
months) enforced server-side by a scheduled function — noted here rather than
silently omitted.

**On the device:** the offline outbox holds the same fields in SQLite, plus the
last-known fix. This is the one place location is on hardware the user can lose,
so it matters that it is minimal: one row per accident, no history of where the
car has been.

**A note on accuracy as a privacy signal.** §26 of the plan says not to store
unnecessary personal information. An accident's location is necessary — it is
the point of the system. What is deliberately *not* stored: the device's
position between accidents, the route taken, or any profile of the driver's
habits.

---

## Emergency contacts

Another person's phone number. The care taken:

- stored **only** inside the owner's `users/{uid}` document;
- the `users` collection has **no `list` grant**, so contact numbers cannot be
  enumerated — only the owner can read their own document;
- `accidents/{id}.notifiedContactIds` stores **ids, not contact objects**,
  because the contacts already live on the profile. A leaked accident record
  therefore leaks no third party's phone number;
- the accident document is not publicly listable.

The app never sends an SMS silently. It opens the **user's composer**
pre-filled, so they see and send the message. Silently dispatching would need a
paid SMS gateway, and would be a decision the user must make — during an
emergency, when they may be the one who cannot act.

---

## BLE security

Stated plainly because it is a real weakness:

> **The BLE link is not encrypted and not authenticated.**

Consequences:

- anyone within radio range can **see** the telemetry (accelerometer readings,
  device state, battery);
- anyone within range can **send** frames, including a `CANCEL`, because the
  custom GATT service has no bonding or pairing requirement;
- the advertised `deviceId`/MAC is a hardware identifier.

What that means in practice, and why it is acceptable for a prototype:

The threat is *someone malicious and physically within BLE range of your car* —
a different and much more specific adversary than "someone can read your data".
Against that adversary the honest mitigations are:

1. **Frame the CRC-16 as integrity, not security.** It detects line noise, not
   tampering. It is not a MAC and the docs say so.
2. **A `CANCEL` is idempotent and benign.** The worst a forged cancel achieves
   is that *this* alert does not fire. Forging `CONFIRM` achieves nothing extra,
   because a forged event still needs a phone-side location to be useful.
3. **The response is not trusted either.** The app re-derives its state from its
   own timer and its own location, and the Firestore rules validate every write.
   A hostile node cannot make the app lie to the cloud.

Properly securing this means GATT bonding plus a per-session key exchange,
which is a real project in itself and is listed as future work rather than
claimed here.

### The FlutterBluePlus licence

`ble_service.dart` uses `License.nonprofit`, correct for a prototype. The plugin
requires a **paid commercial licence** for any for-profit use. A commercial
deployment must change it and buy one — this is a licensing obligation, not a
technical detail.

---

## The honest limitations

| Limitation | Effect |
| --- | --- |
| Location is stored in plain Firestore documents | A database breach exposes locations. Mitigated by rules, not by encryption. |
| No end-to-end encryption of accident records | Firestore encrypts at rest and in transit; a server-side compromise still sees plaintext. |
| No retention policy | Accident records accumulate indefinitely. Must be added before production. |
| No audit log of who read an accident | A responder's access is not recorded. Should be, before granting responders at all. |
| The responder role is designed but unused | No hospital notification path exists today. Do not enable it without the audit log. |
| Analytics/crash reporting | Deliberately absent. A crash reporter would upload location-adjacent data. Add one only with explicit thought about what it sends. |

---

## Before deploying this anywhere real

1. A retention policy, enforced server-side.
2. An audit log for responder access.
3. A real BLE security story, or a documented acceptance of the risk.
4. A commercial FlutterBluePlus licence if it is used commercially.
5. A privacy policy that names Firestore, and a lawful basis for processing
   location data in the user's jurisdiction.
6. Someone else's review of the security rules. They should not be the author.

---

**Next:** [10 — Testing](10-testing.md) · [11 — Deployment](11-deployment.md) · [13 — Troubleshooting](13-troubleshooting.md)
