// event_queue.cpp — §8 stop-and-wait sequencer.
#include "event_queue.h"

namespace saas {

void EventQueue::reset() {
  for (uint8_t i = 0; i < kEventQueueN; i++) {
    slots_[i].len = 0;
    slots_[i].inUse = 0;
  }
  head_ = 0;
  count_ = 0;
  dropped_ = 0;
  attempt_ = 0;
  retryAtMs_ = 0;
  armed_ = false;
}

bool EventQueue::push(const Slot& s, uint32_t nowMs, uint8_t* dropped) {
  (void)nowMs;
  if (count_ >= kEventQueueN) {
    // Full. The newest event is the one that goes: the ones already queued are
    // older, and an ACCIDENT_DETECTED that silently displaces a MANUAL_SOS is a
    // worse failure than one that waits its turn.
    if (dropped_ < 0xFF) dropped_++;
    if (dropped) *dropped = 1;
    return false;
  }
  // Append at the tail, wrapping. Keeping the queue as a ring of slots means a
  // full queue is a bounds check and nothing else -- no memmove, no compaction.
  const uint8_t tail = static_cast<uint8_t>((head_ + count_) % kEventQueueN);
  slots_[tail] = s;
  slots_[tail].inUse = 1;
  count_++;

  // A freshly queued head starts at attempt 0, so a long backlog cannot inherit
  // the retries already spent on a previous event.
  if (count_ == 1) {
    attempt_ = 0;
    armed_ = false;
  }
  if (dropped) *dropped = 0;
  return true;
}

void EventQueue::retire() {
  if (!count_) return;
  slots_[head_].inUse = 0;
  slots_[head_].len = 0;
  head_ = static_cast<uint8_t>((head_ + 1) % kEventQueueN);
  count_--;
  attempt_ = 0;
  armed_ = false;
}

uint32_t EventQueue::nextBackoffMs(uint8_t attempt) const {
  // 750 / 1500 / 3000 for the three retries of §8 step 4. Clamped rather than
  // shifted: kEventMaxRetries could be retuned past 3, and a 16-bit shift of
  // 750 would wrap into a short interval instead of a long one.
  uint32_t ms = kEventRetryMs;
  for (uint8_t i = 0; i < attempt && ms < (0xFFFFFFFFu >> 1); i++) ms <<= 1;
  return ms;
}

void EventQueue::armRetry(uint32_t nowMs, uint8_t attempt) {
  attempt_ = attempt;
  retryAtMs_ = nowMs + nextBackoffMs(attempt);
  armed_ = true;
}

bool EventQueue::retryDue(uint32_t nowMs) const {
  // Unarmed means "never sent yet": the caller sends first, then arms. Making an
  // unarmed queue report due would push every event out twice on the first tick.
  if (!armed_ || !count_) return false;
  // Unsigned compare with no subtraction, so a clock that steps backwards cannot
  // wrap the deadline into the past.
  return nowMs >= retryAtMs_;
}

}  // namespace saas
