// SPDX-License-Identifier: LGPL-2.1-or-later
#include "COTTransportWriter.h"
#include <cerrno>
#include <utility>
namespace cot {
TransportWriter::TransportWriter(Adapter adapter) : adapter_(std::move(adapter)) {}
TransportWriter::~TransportWriter() { close(); }
bool TransportWriter::open(int fd, bool allowsInput) {
  if (fd < 0 || fd_ >= 0) return false;
  ++generation_; fd_ = fd; allowsInput_ = allowsInput;
  error_.clear(); return true;
}
void TransportWriter::close() {
  ++generation_; // All previous readiness callbacks become stale, even on reuse.
  if (armed_) { adapter_.disarmWritable(); armed_ = false; }
  int old = fd_; fd_ = -1; allowsInput_ = false;
  pending_.clear(); offset_ = pendingBytes_ = 0;
  if (old >= 0) adapter_.close(old);
}
void TransportWriter::fail(const char *message) {
  error_ = message;
  close(); // No suffix replay after permanent error; error remains observable.
}
EnqueueResult TransportWriter::enqueue(const char *data, std::size_t length) {
  if (!error_.empty()) return EnqueueResult::Failed;
  if (fd_ < 0 || !allowsInput_) return EnqueueResult::Closed;
  if (length > MaximumPendingBytes - pendingBytes_) return EnqueueResult::Backpressured;
  if (length == 0) return EnqueueResult::Accepted;
  if (!data) { fail("Invalid transport transaction"); return EnqueueResult::Failed; }
  pending_.emplace_back(data, data + length); // Whole immutable transaction.
  pendingBytes_ += length;
  if (!armed_) drain();
  // Accepted describes local admission. A subsequent drain error is separately
  // observable via error(); it never proves child execution or retries for caller.
  return EnqueueResult::Accepted;
}
void TransportWriter::writable(std::uint64_t generation) {
  if (generation != generation_ || fd_ < 0) return;
  drain();
}
void TransportWriter::drain() {
  if (!allowsInput_ || fd_ < 0) return; // Final transport policy boundary.
  while (!pending_.empty()) {
    auto &transaction = pending_.front();
    const std::size_t remaining = transaction.size() - offset_;
    WriteResult result = adapter_.write(fd_, transaction.data() + offset_, remaining);
    if (result.count > 0 && static_cast<std::size_t>(result.count) <= remaining) {
      offset_ += static_cast<std::size_t>(result.count);
      pendingBytes_ -= static_cast<std::size_t>(result.count);
      if (offset_ == transaction.size()) { pending_.pop_front(); offset_ = 0; }
      continue;
    }
    if (result.count < 0 && result.error == EINTR) continue;
    if (result.count < 0 && (result.error == EAGAIN || result.error == EWOULDBLOCK)) {
      if (!armed_) { armed_ = true; adapter_.armWritable(fd_, generation_); }
      return;
    }
    fail("Terminal transport write failed"); return;
  }
  if (armed_) { adapter_.disarmWritable(); armed_ = false; }
}
}
