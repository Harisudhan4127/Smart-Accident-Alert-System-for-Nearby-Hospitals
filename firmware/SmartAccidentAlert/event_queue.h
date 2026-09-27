// event_queue.h — §8 event sequencer, the stop-and-wait reliability layer.
//
// Split out of comm for the same reason the protocol scanner was split out:
// this is where the "notifications are not reliable" part of the spec lives, and
// it is pure logic. It can be stepped from a host test without a radio.
//
// The sequencer owns one slot at a time. `push` refuses rather than overwrites,
// because an ACCIDENT_DETECTED that displaces a MANUAL_SOS is worse than one
// that waits: a dropped *alert* is a safety failure, a queued *alert* is a
// latency.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "config.h"

namespace saas {

/// What the caller must do with a transition. Kept as data, not callbacks, so
/// the sequencer stays testable and the BLE task stays the only thing that knows
/// about NimBLE.
struct QueuedEvent {
  uint8_t type;        ///< proto::EventType
  uint32_t eventId;    ///< stable per-incident id, so retries de-duplicate
  uint16_t tMs;        ///< ms since boot when the event was raised
  uint8_t ageTicks;    ///< how many 1 s housekeeping ticks it has waited
};

class EventQueue {
 public:
  /// Pre-rendered frame. The sequencer never touches the payload: whatever
  /// bytes the builder put there go out on every retry, byte for byte, which is
  /// what makes retransmission idempotent.
  struct Slot {
    uint8_t data[kEventSlotSize];
    uint16_t len;
    uint8_t inUse;
  };

  void reset();

  /// Takes the queue. Full means the newest event is dropped and `dropped` is
  /// set, which the UI surfaces as a red LED rather than a silent loss.
  bool push(const Slot& s, uint32_t nowMs, uint8_t* dropped = nullptr);

  /// Called by the sequencer when a slot has been fully delivered.
  void retire();

  uint8_t depth() const { return count_; }
  bool empty() const { return count_ == 0; }
  bool anyDropped() const { return dropped_ != 0; }
  uint8_t droppedCount() const { return dropped_; }

  /// The slot to send now, or nullptr when idle.
  const Slot* head() const { return (count_ && head_ < kEventQueueN) ? &slots_[head_] : nullptr; }

  /// Start/restart the retry timer for the current attempt. `attempt` counts
  /// retries already made, so attempt 0 waits kEventRetryMs.
  void armRetry(uint32_t nowMs, uint8_t attempt);
  bool retryDue(uint32_t nowMs) const;
  uint8_t attempt() const { return attempt_; }

  /// True once the current event has used up its attempts and must be flagged
  /// undelivered rather than retried forever.
  bool exhausted() const { return attempt_ >= kEventMaxRetries; }
  uint32_t nextBackoffMs(uint8_t attempt) const;

 private:
  Slot slots_[kEventQueueN]{};
  uint8_t head_ = 0;
  uint8_t count_ = 0;
  uint8_t dropped_ = 0;
  uint8_t attempt_ = 0;
  uint32_t retryAtMs_ = 0;
  bool armed_ = false;
};

}  // namespace saas
