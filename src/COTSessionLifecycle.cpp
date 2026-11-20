// SPDX-License-Identifier: LGPL-2.1-or-later
#include "COTSessionLifecycle.h"
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <utility>

// Windows' C library has no SIGHUP. The number only reaches the injected adapter's signal(), and the Windows session
// doesn't use this lifecycle (ConPTY ends its own process), so the core and its tests still build and run there.
#if !defined(SIGHUP)
#define SIGHUP 1
#endif

namespace cot {
namespace {
constexpr int MaximumFinalDrainTurns = 16;
}

SessionLifecycle::SessionLifecycle(Adapter adapter) : adapter_(std::move(adapter)) {}

bool SessionLifecycle::cleanupComplete() const {
  return fd_ < 0 && pid_ <= 0 && readAcked_ && writeAcked_;
}

bool SessionLifecycle::canBegin() const { return completed_ && cleanupComplete(); }

bool SessionLifecycle::begin(int fd, int pid) {
  if (fd < 0 || !canBegin()) return false;
  ++generation_;
  fd_ = fd;
  pid_ = pid > 0 ? pid : -1;
  state_ = LifeState::Running;
  status_ = 0; statusValid_ = false; error_ = 0;
  hupSent_ = false; hupError_ = 0;
  retiring_ = false; ended_ = false; completed_ = false;
  readAcked_ = writeAcked_ = false;
  readCancelRequested_ = writeCancelRequested_ = false;
  return true;
}

void SessionLifecycle::readable(std::uint64_t generation) {
  if (generation != generation_ || fd_ < 0 || retiring_) return;
  drainReads();
}

SessionLifecycle::Drain SessionLifecycle::drainReads() {
  if (reading_) return Drain::Drained;  // No reentrant second reader, even from a callback.
  reading_ = true;
  struct Reset { bool &flag; ~Reset() { flag = false; } } reset{reading_};
  char buffer[ReadChunk];
  for (std::size_t turn = 0; turn < MaximumReadsPerTurn; ++turn) {
    if (fd_ < 0 || retiring_) return Drain::Ended;
    IOResult result = adapter_.read(fd_, buffer, sizeof buffer);
    if (result.count > 0 && static_cast<std::size_t>(result.count) <= sizeof buffer) {
      adapter_.ingest(buffer, static_cast<std::size_t>(result.count));
      continue;
    }
    if (result.count < 0 && result.error == EINTR) continue;
    if (result.count < 0 && (result.error == EAGAIN || result.error == EWOULDBLOCK)) return Drain::Drained;
    // 0 is EOF; Linux reports a closed slave as EIO. Both end the transport,
    // and neither says anything about whether the child has exited.
    if (result.count == 0 || result.error == EIO) endTransport(0);
    else endTransport(result.count < 0 && result.error ? result.error : EINVAL);
    return Drain::Ended;
  }
  return Drain::Budget;  // A level-triggered READ source fires again.
}

void SessionLifecycle::endTransport(int error) {
  if (ended_) return;
  ended_ = true;
  if (adapter_.transportEnded) adapter_.transportEnded(error);
  retireTransport();
}

void SessionLifecycle::reap(std::uint64_t generation) {
  if (generation != generation_ || pid_ <= 0) return;
  WaitResult result = adapter_.waitNoHang(pid_);
  if (result.pid == 0) return;                               // Still running: keep the PID.
  if (result.pid < 0 && result.error == EINTR) return;       // Retry on the next tick.
  if (result.pid == pid_) {
    // Final output first: whatever the child wrote before exiting is ingested
    // before the exit event (bounded; any remainder still arrives afterwards).
    for (int turn = 0; turn < MaximumFinalDrainTurns && fd_ >= 0 && !retiring_; ++turn)
      if (drainReads() != Drain::Budget) break;
    status_ = result.status; statusValid_ = true;
    pid_ = -1; state_ = LifeState::Exited;
    if (adapter_.stopReaper) adapter_.stopReaper();
    if (adapter_.exited) adapter_.exited(status_);
    maybeComplete();
    return;
  }
  // ECHILD, another error, or a PID we don't own: no status is invented.
  error_ = result.pid < 0 ? (result.error ? result.error : EINVAL) : EINVAL;
  pid_ = -1; state_ = LifeState::Unknown;
  if (adapter_.stopReaper) adapter_.stopReaper();
  if (adapter_.unknown) adapter_.unknown(error_);
  maybeComplete();
}

void SessionLifecycle::terminate() {
  if (pid_ > 0 && !hupSent_) {
    hupSent_ = true;
    hupError_ = adapter_.signal ? adapter_.signal(pid_, SIGHUP) : ENOSYS;
    if (state_ == LifeState::Running) state_ = LifeState::Stopping;
  }
  retireTransport();
}

void SessionLifecycle::retireTransport() {
  if (fd_ < 0 || retiring_) return;
  retiring_ = true;
  const std::uint64_t generation = generation_;
  if (!readAcked_ && !readCancelRequested_) {
    readCancelRequested_ = true;
    adapter_.cancelRead();
  }
  if (generation == generation_ && !writeAcked_ && !writeCancelRequested_) {
    writeCancelRequested_ = true;
    adapter_.cancelWrite();
  }
  maybeCloseDescriptor();
}

void SessionLifecycle::readCancelled(std::uint64_t generation) {
  if (generation != generation_ || readAcked_) return;
  readAcked_ = true;
  maybeCloseDescriptor();
}

void SessionLifecycle::writeCancelled(std::uint64_t generation) {
  if (generation != generation_ || writeAcked_) return;
  writeAcked_ = true;  // The writer may retire alone (a write failure) before the reader.
  maybeCloseDescriptor();
}

void SessionLifecycle::maybeCloseDescriptor() {
  if (!retiring_ || fd_ < 0 || !readAcked_ || !writeAcked_) return;
  const int fd = fd_;
  fd_ = -1;
  adapter_.close(fd);
  maybeComplete();
}

void SessionLifecycle::maybeComplete() {
  if (completed_ || !cleanupComplete()) return;
  completed_ = true;
  if (adapter_.cleanupComplete) adapter_.cleanupComplete();
}

bool WaitForQuiescence(const std::function<bool()> &clean, const std::function<double()> &now,
                       const std::function<void(double)> &step, double timeoutSeconds) {
  const double deadline = now() + std::max(0.0, timeoutSeconds);
  while (!clean()) {
    const double left = deadline - now();
    if (left <= 0) return clean();
    step(std::min(left, 0.01));
  }
  return true;
}
}
