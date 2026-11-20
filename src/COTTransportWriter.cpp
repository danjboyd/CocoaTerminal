// SPDX-License-Identifier: LGPL-2.1-or-later
#include "COTTransportWriter.h"
#include <algorithm>
#include <cerrno>
#include <limits>
#include <utility>
namespace cot {
TransportWriter::TransportWriter(Adapter adapter) : adapter_(std::move(adapter)) {}
TransportWriter::~TransportWriter() { close(); }
bool TransportWriter::open(int fd, bool allowsInput) {
  if (fd < 0 || fd_ >= 0) return false;
  ++generation_; fd_ = fd; allowsInput_ = allowsInput;
  driver_ = DriverState::Idle; noProgressTurns_ = 0; continuationTicket_ = 0;
  error_.clear(); return true;
}
void TransportWriter::close() {
  ++generation_;
  const bool disarm = driver_ == DriverState::WritableWaiting;
  driver_ = DriverState::Closed; // Invalidate both callback drivers FIRST.
  int old = fd_; fd_ = -1; allowsInput_ = false;
  pending_.clear(); offset_ = pendingBytes_ = noProgressTurns_ = 0;
  if (disarm) adapter_.disarmWritable();
  if (old >= 0) adapter_.close(old);
}
void TransportWriter::fail(const char *message) {
  error_ = message;
  close(); // Explicitly observable failure/cancellation, never silent suffix loss.
}
EnqueueResult TransportWriter::enqueue(const char *data, std::size_t length) {
  if (!error_.empty()) return EnqueueResult::Failed;
  if (fd_ < 0 || !allowsInput_) return EnqueueResult::Closed;
  if (length > MaximumPendingBytes - pendingBytes_) return EnqueueResult::Backpressured;
  if (length == 0) return EnqueueResult::Accepted;
  if (!data) { fail("Invalid transport transaction"); return EnqueueResult::Failed; }
  pending_.emplace_back(data, data + length);
  pendingBytes_ += length;
  if (driver_ == DriverState::Idle) drain();
  return EnqueueResult::Accepted; // Local admission, never execution evidence.
}
void TransportWriter::writable(std::uint64_t generation) {
  if (generation != generation_ || fd_ < 0 || driver_ != DriverState::WritableWaiting) return;
  driver_ = DriverState::Idle;
  adapter_.disarmWritable(); // No writable driver may overlap a continuation.
  drain();
}
void TransportWriter::resume(std::uint64_t generation, std::uint64_t ticket) {
  if (generation != generation_ || fd_ < 0 || driver_ != DriverState::ContinuationPending || ticket != continuationTicket_) return;
  if (draining_) { fail("Writer continuation must be asynchronous; pending input cancelled"); return; }
  driver_ = DriverState::Idle;
  drain();
}
void TransportWriter::drain() {
  if (!allowsInput_ || fd_ < 0 || driver_ != DriverState::Idle) return;
  if (draining_) { fail("Reentrant writer drain; pending input cancelled"); return; }
  draining_ = true;
  struct Reset { bool &flag; ~Reset() { flag = false; } } reset{draining_};
  std::size_t calls = 0, bytes = 0;
  while (!pending_.empty() && calls < MaximumCallsPerDrain && bytes < MaximumBytesPerDrain) {
    auto &transaction = pending_.front();
    const std::size_t remaining = transaction.size() - offset_;
    const std::size_t offer = std::min(remaining, MaximumBytesPerDrain - bytes);
    ++calls; // EINTR consumes work budget too.
    WriteResult result = adapter_.write(fd_, transaction.data() + offset_, offer);
    if (result.count > 0 && static_cast<std::size_t>(result.count) <= offer) {
      const auto written = static_cast<std::size_t>(result.count);
      offset_ += written; pendingBytes_ -= written; bytes += written;
      noProgressTurns_ = 0;
      if (offset_ == transaction.size()) { pending_.pop_front(); offset_ = 0; }
      continue;
    }
    if (result.count < 0 && result.error == EINTR) continue;
    if (result.count < 0 && (result.error == EAGAIN || result.error == EWOULDBLOCK)) {
      noProgressTurns_ = 0; // Wait for external readiness, never self-spin.
      driver_ = DriverState::WritableWaiting;
      adapter_.armWritable(fd_, generation_);
      return;
    }
    fail("Terminal transport write failed"); return;
  }
  if (pending_.empty()) return;
  if (bytes == 0 && ++noProgressTurns_ >= MaximumNoProgressTurns) {
    fail("Terminal transport made no progress for 8 drain turns; pending input cancelled"); return;
  }
  if (!adapter_.scheduleContinuation || continuationTicket_ == std::numeric_limits<std::uint64_t>::max()) {
    fail("Writer continuation unavailable; pending input cancelled"); return;
  }
  driver_ = DriverState::ContinuationPending;
  adapter_.scheduleContinuation(generation_, ++continuationTicket_);
}
}
