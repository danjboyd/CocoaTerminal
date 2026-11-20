// SPDX-License-Identifier: LGPL-2.1-or-later
// Patch B (goal 685): one owner per generation for the master fd, its single
// reader, the direct child's PID/raw wait status and the fd retirement barrier.
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace cot {
// Idle: never started. Running: child owned. Stopping: HUP sent, child still
// owned. Exited: raw status obtained. Unknown: reaping failed (ECHILD etc.);
// no status is invented.
enum class LifeState { Idle, Running, Stopping, Exited, Unknown };
struct IOResult { std::ptrdiff_t count; int error; };
// pid > 0 and == child: reaped with status. 0: still running. -1: error.
struct WaitResult { int pid; int status; int error; };

// Every method must run on the same serial owner as the TransportWriter.
// Adapter callbacks run on that owner; cancelRead/cancelWrite may acknowledge
// inline or later, but only through readCancelled/writeCancelled.
class SessionLifecycle {
 public:
  struct Adapter {
    std::function<IOResult(int, char *, std::size_t)> read;
    std::function<void(const char *, std::size_t)> ingest;  // the ONE consumer
    std::function<WaitResult(int)> waitNoHang;
    std::function<int(int, int)> signal;  // returns 0 or errno
    std::function<void()> cancelRead;
    std::function<void()> cancelWrite;
    std::function<void(int)> close;       // the ONLY closer of the master fd
    std::function<void()> stopReaper;
    std::function<void(int)> exited;      // raw wait status, at most once per generation
    std::function<void(int)> unknown;     // errno, at most once per generation
    std::function<void(int)> transportEnded;  // 0 for EOF/EIO, else errno; once
    std::function<void()> cleanupComplete;    // once per generation
  };
  static constexpr std::size_t ReadChunk = 8192;
  static constexpr std::size_t MaximumReadsPerTurn = 64;

  explicit SessionLifecycle(Adapter adapter);
  SessionLifecycle(const SessionLifecycle &) = delete;
  SessionLifecycle &operator=(const SessionLifecycle &) = delete;

  // Refused (false) while a previous generation still holds an fd, a child,
  // or an unacknowledged cancellation. pid may be -1 for an fd-only transport.
  bool begin(int fd, int pid);
  // READ source event: reads until EAGAIN or the per-turn budget. EOF/EIO is a
  // transport event and retires the transport; it never waits for the child.
  void readable(std::uint64_t generation);
  // Reaper tick: one waitpid(WNOHANG). On reap, pending output is drained
  // first so final output precedes the exit event.
  void reap(std::uint64_t generation);
  // SIGHUP once to the direct child (never a group, never escalated), then
  // retire the transport. Reaping continues until the child is actually reaped.
  void terminate();
  // Cancel the reader and writer; close the fd only after BOTH acknowledge.
  void retireTransport();
  void readCancelled(std::uint64_t generation);
  void writeCancelled(std::uint64_t generation);

  LifeState state() const { return state_; }
  std::uint64_t generation() const { return generation_; }
  int descriptor() const { return fd_; }
  int childPid() const { return pid_; }
  bool statusValid() const { return statusValid_; }
  int rawStatus() const { return status_; }
  int lastError() const { return error_; }
  bool hangupSent() const { return hupSent_; }
  int hangupError() const { return hupError_; }
  bool transportOpen() const { return fd_ >= 0 && !retiring_; }
  bool cleanupComplete() const;
  bool canBegin() const;

 private:
  enum class Drain { Drained, Budget, Ended };
  Drain drainReads();
  void endTransport(int error);
  void maybeCloseDescriptor();
  void maybeComplete();
  Adapter adapter_;
  LifeState state_ = LifeState::Idle;
  std::uint64_t generation_ = 0;
  int fd_ = -1;
  int pid_ = -1;
  int status_ = 0;
  bool statusValid_ = false;
  int error_ = 0;
  bool hupSent_ = false;
  int hupError_ = 0;
  bool retiring_ = false;
  bool readAcked_ = true;
  bool writeAcked_ = true;
  bool readCancelRequested_ = false;
  bool writeCancelRequested_ = false;
  bool ended_ = false;
  bool completed_ = true;
  bool reading_ = false;
};

// App-quit helper: pumps `step` until `clean` holds or `timeoutSeconds` pass on
// `now`. Returns whether everything finished; never waits past the deadline.
bool WaitForQuiescence(const std::function<bool()> &clean, const std::function<double()> &now,
                       const std::function<void(double)> &step, double timeoutSeconds);
}
