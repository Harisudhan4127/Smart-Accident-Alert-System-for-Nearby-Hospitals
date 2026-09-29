# 33\. What the app asks for, and when

This is the complete list of Android permissions the app can request, why each
one exists, and the exact moment it is requested. It exists because "why does an
accident app want my location" is a fair question, and an app that cannot answer
it gets its permissions refused.

## The short version

**The app asks for nothing when it starts.** You will see the full list of what
it needs, and it will get on with the parts of the app that work without any of
it.

| Permission | Asked when | If you say no |
| --- | --- | --- |
| **Nearby devices** (Bluetooth) | you tap *Connect* and it scans for your node | cannot reach the node; everything else works |
| **Location** | an accident event arrives and a position is needed | the accident is still detected and recorded, with no position |
| **Notifications** | the first alert is raised | you will not be warned if the app is closed |

Nothing here is fatal. The app is usable with every permission refused, which is
`PROJECT_PLAN.md` §25's requirement that failures be handled by degrading rather
than by refusing to start.

## There is no Wi-Fi permission

Worth saying plainly, because the Bluetooth dialog is routinely mistaken for one.
On Android 12+ the system prompt reads:

> Allow *Smart Accident Alert* to find and connect to devices near you?

That is the **Nearby devices** permission, and it is Bluetooth. It looks like a
networking prompt because Android groups all short-range radio under it. The app
requests no Wi-Fi permission at all, and it never touches your saved Wi-Fi
networks.

`ACCESS_NETWORK_STATE` *is* declared, but it is an install-time permission: the
OS never shows a dialog for it, and it only lets the app tell "no internet" from
"internet" so it can queue accidents and upload them later.

## Nearby devices — Bluetooth

**Why.** The ESP32 node advertises a BLE service. Without this, the app cannot see
it at all.

**When.** The first time you scan for a node, not at launch. Before this was
changed, a permission dialog for "nearby devices" appeared on the splash screen —
before the user had seen a single screen, let alone been told what a node is.
People deny that prompt, and then the app looks permanently broken because it
can never scan.

**Also needed for scanning on Android 10+:** `ACCESS_FINE_LOCATION`. This is an
Android requirement rather than an app choice — from Android 10 the OS treats a
BLE scan as potentially deriving location and requires the grant. The node
advertises a service UUID, not a location beacon, and the app never uses scan
results to infer where you are.

## Location

**Why.** `PROJECT_PLAN.md` §1: the accident's position comes from the phone's
GPS, because the phone is already in the car. Without it the node cannot dispatch
anyone — it has no idea where it is.

**When.** When an accident event arrives, at the moment a position is actually
needed. This is the permission an accident app is most often refused, and asking
for it at launch is the main reason: the request arrives with no context, so the
only available answer is a reflexive "no". Asked at the moment an alert is on
screen, the answer is usually yes.

**If refused.** The accident is still detected, recorded, timestamped and sent.
The hospital search and map need a position, so the app says plainly that the
location is missing rather than showing a map of nowhere.

**Background location** is declared but **never requested**, and this is
deliberate. Android 11+ shows it on a separate screen with its own wording, and it
is the single most alarming prompt an app can show. It is also unnecessary here:
the app is in use when an accident arrives, and the node keeps detecting and
queueing whether or not the phone app is open.

## Notifications

**Why.** So an alert reaches you when the app is not in front of you.

**When.** The first time an alert is raised. Before this was changed the app asked
on the splash screen, where the question "allow notifications?" is
unanswerable — the user has not seen an alert yet, and a refusal there is the one
that actually costs them an emergency.

**If refused.** The alert is still shown in-app, and still written to history.

## The startup check list

The splash screen runs five checks. **All five are reads — none of them prompts.**

| Row | What it means | Can you fix it here? |
| --- | --- | --- |
| Bluetooth | whether the radio is on and permitted | yes — a **Turn on Bluetooth** button appears when it is off |
| Location | what the permission state is | no — it is asked at the moment it is needed |
| Hospital directory | the offline hospital list has loaded | no |
| Cloud sync | whether Firebase is reachable | no — the app works fully offline |
| Notifications | what the permission state is | no — it is asked when the first alert is raised |

Only one case is fatal: a device with **no Bluetooth radio at all**. Everything
else is a warning, and the app starts regardless. A phone app that refuses to open
because a car accessory is out of range is a bad phone app.

## Permissions and the demo mode

The in-memory simulator (`flutter run --dart-define=DEMO=true`) needs **no
permissions whatsoever** — there is no radio, no GPS and no cloud involved. It is
the fastest way to see the whole product working, and it is worth doing before
wiring any hardware.
