// state_machine.cpp — the §7 guard table.
#include "state_machine.h"

namespace saas {
namespace {

// A cell that changes nothing, because the event is meaningless in that state.
constexpr Transition kNoOp(uint8_t s) { return Transition{s, s, kEvNone, 0, 0, 0}; }
constexpr Transition kStay(uint8_t s, uint8_t ev) { return Transition{s, s, ev, 0, 1, 0}; }
constexpr Transition kGo(uint8_t from, uint8_t to, uint8_t ev, uint8_t dispatch) {
  return Transition{from, to, ev, dispatch, 1, 0};
}

// The table, written out in full: [event][state].
//
// `emit` is the event the caller must queue *when it takes this edge*. A
// refused event emits nothing and leaves the state alone, which is what makes
// the illegal cells safe rather than merely unlikely.
constexpr Transition kTable[kTriggerCount][proto::kStateCount] = {
    // ---- kFusedTrip: the detector crossed threshold -----------------------
    // Only IDLE can open a cancel window. A trip while already alarming is a
    // second crash: it must not restart the countdown, and it must not be lost
    // either, so it is a no-op here and picked up by the ALARM state itself.
    /* kFusedTrip   */ {kNoOp(proto::kStateBoot), kGo(proto::kStateIdle, proto::kStatePending, proto::kEvAccidentDetected, 0),
                        kNoOp(proto::kStatePending), kNoOp(proto::kStateAlarm), kNoOp(proto::kStateSos),
                        kNoOp(proto::kStateMuted), kNoOp(proto::kStateFault)},

    // ---- kManualSos: the physical button ----------------------------------
    // From PENDING the button is a confirm, not a new incident: the user is
    // standing next to a crashed vehicle, and the countdown must not keep
    // running. During the SOS countdown it means "yes, dispatch now".
    /* kManualSos   */ {kNoOp(proto::kStateBoot), kGo(proto::kStateIdle, proto::kStateSos, proto::kEvManualSos, 0),
                        kGo(proto::kStatePending, proto::kStateAlarm, proto::kEvAlertConfirmed, 1),
                        kNoOp(proto::kStateAlarm), kGo(proto::kStateSos, proto::kStateAlarm, proto::kEvAlertConfirmed, 1),
                        kGo(proto::kStateMuted, proto::kStateSos, proto::kEvManualSos, 0), kNoOp(proto::kStateFault)},

    // ---- kConfirm: COMMAND{CONFIRM}, or the window elapsed ----------------
    /* kConfirm     */ {kNoOp(proto::kStateBoot), kNoOp(proto::kStateIdle),
                        kGo(proto::kStatePending, proto::kStateAlarm, proto::kEvAlertConfirmed, 1),
                        kStay(proto::kStateAlarm, kEvNone), kGo(proto::kStateSos, proto::kStateAlarm, proto::kEvAlertConfirmed, 1),
                        kNoOp(proto::kStateMuted), kNoOp(proto::kStateFault)},

    // ---- kCancel: COMMAND{CANCEL}, or the button during a countdown --------
    /* kCancel      */ {kNoOp(proto::kStateBoot), kNoOp(proto::kStateIdle),
                        kGo(proto::kStatePending, proto::kStateIdle, proto::kEvAlertCancelled, 0),
                        kGo(proto::kStateAlarm, proto::kStateIdle, proto::kEvAlertCancelled, 0),
                        kGo(proto::kStateSos, proto::kStateIdle, proto::kEvAlertCancelled, 0),
                        kNoOp(proto::kStateMuted), kNoOp(proto::kStateFault)},

    // ---- kAlertSent: the phone ACKed that dispatch started -----------------
    // ALARM is where the device *stays* while help is en route. RESOLVED is what
    // ends it, and only the user may send that.
    /* kAlertSent   */ {kNoOp(proto::kStateBoot), kNoOp(proto::kStateIdle), kNoOp(proto::kStatePending),
                        kStay(proto::kStateAlarm, proto::kEvAlertSent),
                        kGo(proto::kStateSos, proto::kStateAlarm, proto::kEvAlertSent, 1), kNoOp(proto::kStateMuted),
                        kNoOp(proto::kStateFault)},

    // ---- kResolved: the user closed the incident --------------------------
    // Also the way out of FAULT, so a cleared sensor fault does not need a
    // reboot; and out of SOS, for a false alarm the user dismisses.
    /* kResolved    */ {kNoOp(proto::kStateBoot), kNoOp(proto::kStateIdle),
                        kGo(proto::kStatePending, proto::kStateIdle, proto::kEvResolved, 0),
                        kGo(proto::kStateAlarm, proto::kStateIdle, proto::kEvResolved, 0),
                        kGo(proto::kStateSos, proto::kStateIdle, proto::kEvResolved, 0), kNoOp(proto::kStateMuted),
                        kGo(proto::kStateFault, proto::kStateIdle, proto::kEvResolved, 0)},

    // ---- kFault: sensor loss, watchdog, or a failed self-test --------------
    // Legal from every state, BOOT included: a device whose sensor did not answer
    // must be able to say so. This is the one row that is not a sparse set of
    // cases, and deliberately so.
    /* kFault       */ {kGo(proto::kStateBoot, proto::kStateFault, proto::kEvDeviceFault, 0),
                        kGo(proto::kStateIdle, proto::kStateFault, proto::kEvDeviceFault, 0),
                        kGo(proto::kStatePending, proto::kStateFault, proto::kEvDeviceFault, 0),
                        kGo(proto::kStateAlarm, proto::kStateFault, proto::kEvDeviceFault, 0),
                        kGo(proto::kStateSos, proto::kStateFault, proto::kEvDeviceFault, 0),
                        kGo(proto::kStateMuted, proto::kStateFault, proto::kEvDeviceFault, 0),
                        kStay(proto::kStateFault, kEvNone)}};

static_assert(sizeof(kTable) / sizeof(kTable[0]) == kTriggerCount, "one row per event");
static_assert(sizeof(kTable[0]) / sizeof(kTable[0][0]) == proto::kStateCount, "one column per state");

/// True for the states that run a cancel countdown, i.e. the ones the deadline
/// applies to.
bool counting(uint8_t s) { return s == proto::kStatePending || s == proto::kStateSos; }

}  // namespace

const Transition& guardCell(uint8_t state, uint8_t trigger) {
  static const Transition kOutOfRange = kNoOp(0xFF);
  if (state >= proto::kStateCount || trigger >= kTriggerCount) return kOutOfRange;
  return kTable[trigger][state];
}

void StateMachine::reset() {
  state_ = proto::kStateBoot;
  pendingSinceMs_ = 0;
}

Transition StateMachine::dispatch(Trigger t, uint32_t nowMs, bool automatic) {
  const uint8_t from = state_;
  Transition tr = guardCell(from, static_cast<uint8_t>(t));
  tr.automatic = automatic ? 1 : 0;

  if (!tr.legal) return tr;  // `to` is already `from`: nothing moved

  state_ = tr.to;

  // The countdown only runs for the states that have one, and it is (re)started
  // on the edge that *enters* a counting state. Leaving one always clears it, so
  // a stale deadline can never fire into IDLE.
  if (counting(tr.to) && !counting(from)) {
    pendingSinceMs_ = nowMs;
  } else if (!counting(tr.to)) {
    pendingSinceMs_ = 0;
  }
  return tr;
}

Transition StateMachine::trip(uint32_t nowMs) { return dispatch(Trigger::kFusedTrip, nowMs); }

Transition StateMachine::onTick(uint32_t nowMs) {
  if (!counting(state_)) return Transition{state_, state_, kEvNone, 0, 0, 0};
  // Unsigned arithmetic: a clock that jumps backwards must not wrap into
  // "expired", which is exactly what `nowMs - deadline < 0` would do if it were
  // written as a signed comparison. Comparing magnitudes avoids the trap.
  if (nowMs < pendingSinceMs_ || nowMs - pendingSinceMs_ < confirmWindowMs()) {
    return Transition{state_, state_, kEvNone, 0, 0, 0};
  }
  return dispatch(Trigger::kConfirm, nowMs, /*automatic=*/true);
}

uint8_t StateMachine::flags(bool buzzerActive, bool ledRed, bool ledGreen, bool oledOk, bool sosHeld,
                            bool charging) const {
  uint8_t f = 0;
  if (buzzerActive) f |= proto::kFlagBuzzer;
  if (ledRed) f |= proto::kFlagLedRed;
  if (ledGreen) f |= proto::kFlagLedGreen;
  if (oledOk) f |= proto::kFlagOledOk;
  if (sosHeld) f |= proto::kFlagSosButton;
  // ARMED mirrors the setting, not the state: MUTED is a consequence of it, and
  // telemetry during an alarm should still report the detector as armed.
  if (settings_.armed) f |= proto::kFlagArmed;
  if (charging) f |= proto::kFlagCharging;
  return f;
}

}  // namespace saas
