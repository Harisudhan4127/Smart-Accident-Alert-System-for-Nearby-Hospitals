// state_machine.h — §7 of docs/02-ble-protocol.md.
//
// The whole point of this file is the guard table. Every combination of
// {event x state} that a *user* can reach is legal, because a person pressing
// the SOS button during the cancel window is not an error condition — it is
// the single most likely thing that will ever happen to this firmware, and it
// must cancel the countdown rather than wedge the detector. So the table is
// written out in full, 7 states x 7 events, with the illegal cells marked as
// such rather than left to a chain of `if`s that can drift out of sync with
// the diagram in the spec.
#pragma once

#include <stdint.h>

#include "config.h"
#include "protocol.h"

namespace saas {

/// The seven events the guard table is indexed by. Deliberately seven: those are
/// the user- and detector-visible actions, and the spec calls for a 7x7 table.
/// Things that are really *settings* (ARM/DISARM) are not in here — they move
/// IDLE<->MUTED through Settings::armed, not through the guard table.
enum class Trigger : uint8_t {
  kFusedTrip = 0,   ///< the detector crossed kTripScore
  kManualSos,       ///< physical SOS button
  kConfirm,         ///< COMMAND{CONFIRM}, or the cancel window elapsed
  kCancel,          ///< COMMAND{CANCEL}, or the button during PENDING/SOS
  kAlertSent,       ///< the phone ACKed that dispatch started
  kResolved,        ///< the user marked the incident resolved
  kFault,           ///< sensor fault, watchdog, or a failed self-test
  kCount
};
constexpr uint8_t kTriggerCount = static_cast<uint8_t>(Trigger::kCount);

/// The result of offering one (event, state) pair to the machine.
struct Transition {
  uint8_t from;              ///< state before
  uint8_t to;                ///< state after (== from when illegal)
  uint8_t emit;              ///< proto::EventType to send, or kEvNone
  uint8_t dispatch;          ///< 1 if the phone must now alert hospitals
  uint8_t legal;             ///< 0 if the guard rejected the event
  uint8_t automatic;         ///< 1 if this came from a timer, not a person
};

/// Sentinel for Transition::emit. protocol.h has no such value, and 0xFF is
/// also what an out-of-range EventType maps to, so the two agree.
constexpr uint8_t kEvNone = 0xFF;

/// Runtime-settable configuration (§6.4 CONFIG). Defaults come from config.h so
/// there is one place to look; the CONFIG message may move any of them.
struct Settings {
  uint16_t accelThresholdMg = kCfgAccelThresholdMgDefault;
  uint16_t debounceMs = kCfgDebounceMsDefault;
  uint16_t confirmWindowSec = kCfgConfirmWindowSecDefault;
  uint32_t muteUntilUnixS = kCfgMuteUntilDefault;
  uint32_t minSpeedMilliKmh = kCfgMinSpeedMilliKmhDefault;
  uint16_t gainMilli = kCfgGainMilliDefault;
  bool vibrationRequired = kCfgVibrationRequiredDefault;
  bool buzzerEnabled = kCfgBuzzerEnabledDefault;
  bool ledEnabled = kCfgLedEnabledDefault;
  bool autoArm = kCfgAutoArmDefault;
  /// The other half of MUTED. Clear this and the machine sits in MUTED.
  bool armed = true;
};

/// The accident state machine. Owns nothing but its own state: no globals, no
/// heap, no I/O, so it can be stepped from a host test as easily as from a task.
class StateMachine {
 public:
  StateMachine() = default;

  void reset();
  /// BOOT -> IDLE. Called once the sensors have answered; also clears FAULT.
  void sensorsOk() { state_ = armedState(); }

  uint8_t state() const { return state_; }
  const char* stateName() const { return proto::stateName(state_); }

  /// Millisecond timestamp at which a PENDING countdown started, or 0 if not
  /// counting. 0 is a safe sentinel: a trip at t=0 re-arms the timer before the
  /// caller can read this.
  uint32_t pendingSinceMs() const { return pendingSinceMs_; }
  uint32_t confirmDeadlineMs() const { return pendingSinceMs_ + confirmWindowMs(); }
  uint32_t confirmWindowMs() const {
    return static_cast<uint32_t>(settings_.confirmWindowSec) * 1000u;
  }

  Settings& settings() { return settings_; }
  const Settings& settings() const { return settings_; }

  /// True while the buzzer should be silent because of a MUTE that has not
  /// expired. Reads the wall clock, not uptime, because the app sends an
  /// absolute `untilUnixS`.
  bool mutedByClock(uint32_t nowUnixS) const {
    return settings_.muteUntilUnixS != 0 && nowUnixS < settings_.muteUntilUnixS;
  }

  /// The one place transitions are decided. Returns the full result so the
  /// caller can render the state change and queue the event in one pass.
  /// `automatic` distinguishes a timer expiry from a person pressing something;
  /// it never changes which transitions are legal.
  Transition dispatch(Trigger t, uint32_t nowMs, bool automatic = false);

  /// The kFusedTrip transition, plus the deadline bookkeeping the caller's
  /// `nowMs` needs. Convenience over `dispatch` so the countdown cannot be
  /// started without the state changing.
  Transition trip(uint32_t nowMs);

  /// Timer tick: fires kConfirm when the PENDING/SOS countdown has expired.
  /// Returns kEvNone when nothing is due, so the caller can ignore it.
  Transition onTick(uint32_t nowMs);

  /// IDLE when armed, MUTED when not. The one place that pair is decided.
  uint8_t armedState() const { return settings_.armed ? proto::kStateIdle : proto::kStateMuted; }

  /// Snapshot for STATUS/telemetry.
  uint8_t flags(bool buzzerActive, bool ledRed, bool ledGreen, bool oledOk, bool sosHeld,
                bool charging) const;

 private:
  Settings settings_{};
  uint8_t state_ = proto::kStateBoot;
  uint32_t pendingSinceMs_ = 0;
};

/// The guard table, exposed so the host test can walk all kStateCount *
/// kTriggerCount cells rather than only the ones a scenario happens to hit.
const Transition& guardCell(uint8_t state, uint8_t trigger);

}  // namespace saas
