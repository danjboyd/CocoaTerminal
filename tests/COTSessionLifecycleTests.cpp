// SPDX-License-Identifier: LGPL-2.1-or-later
// Injected-adapter tests for patch B (goal 685): one reader, reap/cleanup and
// the quit wait. No OS descriptor, process, dispatch, PTY, GUI or clipboard.
#include "COTSessionLifecycle.h"
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <set>
#include <string>
#include <vector>
using namespace cot;
static int failures = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { std::cerr << __LINE__ << ": " << msg << "\n"; ++failures; } } while (0)

struct Read { std::ptrdiff_t count; int error; std::string data; };
static Read Bytes(const std::string &s) { return {static_cast<std::ptrdiff_t>(s.size()), 0, s}; }
static Read Err(int e) { return {-1, e, ""}; }
static Read Eof() { return {0, 0, ""}; }

struct Fake {
  std::deque<Read> reads;            // exhausted -> EAGAIN
  std::deque<WaitResult> waits;      // exhausted -> still running
  int signalResult = 0;
  bool ackReadInline = false, ackWriteInline = false;
  SessionLifecycle *life = nullptr;
  std::string ingested, log;
  std::set<int> openFds;             // resource accounting
  std::set<int> ownedPids;
  int readCalls = 0, waitCalls = 0, closes = 0, doubleCloses = 0, stops = 0, cancelReads = 0, cancelWrites = 0;
  std::vector<std::pair<int, int>> signals;
  SessionLifecycle::Adapter adapter() {
    SessionLifecycle::Adapter a;
    a.read = [this](int, char *buf, std::size_t len) {
      ++readCalls;
      if (reads.empty()) return IOResult{-1, EAGAIN};
      Read r = reads.front(); reads.pop_front();
      if (r.count > 0) { std::size_t n = std::min(len, r.data.size()); std::memcpy(buf, r.data.data(), n); return IOResult{static_cast<std::ptrdiff_t>(n), 0}; }
      return IOResult{r.count, r.error};
    };
    a.ingest = [this](const char *d, std::size_t n) { ingested.append(d, n); log += "data;"; };
    a.waitNoHang = [this](int pid) {
      ++waitCalls;
      if (waits.empty()) return WaitResult{0, 0, 0};
      WaitResult w = waits.front(); waits.pop_front();
      if (w.pid == pid) ownedPids.erase(pid);
      return w;
    };
    a.signal = [this](int pid, int sig) { signals.push_back({pid, sig}); return signalResult; };
    a.cancelRead = [this]() { ++cancelReads; log += "cancelRead;"; if (ackReadInline) life->readCancelled(life->generation()); };
    a.cancelWrite = [this]() { ++cancelWrites; log += "cancelWrite;"; if (ackWriteInline) life->writeCancelled(life->generation()); };
    a.close = [this](int fd) { ++closes; if (!openFds.erase(fd)) ++doubleCloses; log += "close;"; };
    a.stopReaper = [this]() { ++stops; };
    a.exited = [this](int s) { log += "exit" + std::to_string(s) + ";"; };
    a.unknown = [this](int e) { log += "unknown" + std::to_string(e) + ";"; };
    a.transportEnded = [this](int e) { log += "ended" + std::to_string(e) + ";"; };
    a.cleanupComplete = [this]() { log += "clean;"; };
    return a;
  }
  void start(SessionLifecycle &l, int fd, int pid) { life = &l; openFds.insert(fd); if (pid > 0) ownedPids.insert(pid); }
  bool leakFree() const { return openFds.empty() && ownedPids.empty() && doubleCloses == 0; }
};

static int Exit(int code) { return (code & 0xff) << 8; }  // raw wait status, as waitpid reports it on Linux

int main() {
  // 1. One reader: chunks are ingested in read order, EINTR retried, EAGAIN stops the turn.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, 100);
    EXPECT(l.begin(10, 100), "begin");
    f.reads = {Bytes("ab"), Err(EINTR), Bytes("cd"), Err(EAGAIN), Bytes("ef")};
    l.readable(l.generation());
    EXPECT(f.ingested == "abcd", "read order up to EAGAIN: " << f.ingested);
    l.readable(l.generation());
    EXPECT(f.ingested == "abcdef", "next event continues in order");
    EXPECT(l.state() == LifeState::Running && l.transportOpen(), "still running");
  }
  // 2. Per-turn budget: a flood yields after MaximumReadsPerTurn reads.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, -1); l.begin(10, -1);
    for (int i = 0; i < 100; ++i) f.reads.push_back(Bytes("x"));
    l.readable(l.generation());
    EXPECT(f.readCalls == (int)SessionLifecycle::MaximumReadsPerTurn, "budget " << f.readCalls);
    EXPECT(f.ingested.size() == SessionLifecycle::MaximumReadsPerTurn, "ingested within budget");
  }
  // 3. EOF before exit: transport ends and retires, no wait is made, the child stays owned.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, 100); l.begin(10, 100);
    f.reads = {Bytes("bye"), Eof()};
    l.readable(l.generation());
    EXPECT(f.waitCalls == 0, "EOF never waits for the child");
    EXPECT(f.log == "data;ended0;cancelRead;cancelWrite;", "EOF retires: " << f.log);
    EXPECT(l.childPid() == 100 && l.state() == LifeState::Running, "child still owned after EOF");
    EXPECT(f.closes == 0, "no close before both cancellations acknowledge");
    l.readCancelled(l.generation());
    EXPECT(f.closes == 0, "read ack alone does not close");
    l.writeCancelled(l.generation());
    EXPECT(f.closes == 1 && l.descriptor() == -1, "closed after both acks");
    EXPECT(!l.cleanupComplete() && !l.canBegin(), "not clean while the child is unreaped");
    l.reap(l.generation());
    EXPECT(l.childPid() == 100, "WNOHANG 0 keeps the PID");
    f.waits = {{-1, 0, EINTR}};
    l.reap(l.generation());
    EXPECT(l.childPid() == 100, "EINTR keeps the PID");
    f.waits = {{100, Exit(3), 0}};
    l.reap(l.generation());
    EXPECT(l.state() == LifeState::Exited && l.statusValid() && l.rawStatus() == Exit(3), "status kept");
    EXPECT(f.log.find("exit768;clean;") != std::string::npos, "exit then clean: " << f.log);
    EXPECT(f.stops == 1 && l.cleanupComplete() && l.canBegin(), "reaper stopped and clean");
    EXPECT(f.leakFree(), "no leaked fd or pid");
  }
  // 4. Linux PTY: a closed slave reads as EIO, which is EOF, not an error.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.ackReadInline = f.ackWriteInline = true;
    f.start(l, 10, -1); l.begin(10, -1);
    f.reads = {Err(EIO)};
    l.readable(l.generation());
    EXPECT(f.log == "ended0;cancelRead;cancelWrite;close;clean;", "EIO is EOF: " << f.log);
    EXPECT(f.leakFree() && l.canBegin(), "fd-only transport clean");
  }
  // 5. Final output precedes the exit event; the status is delivered exactly once.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, 100); l.begin(10, 100);
    f.reads = {Bytes("last words")};
    f.waits = {{100, Exit(1), 0}};
    l.reap(l.generation());
    EXPECT(f.log == "data;exit256;", "final output before exit: " << f.log);
    f.waits = {{100, Exit(9), 0}};
    l.reap(l.generation());
    EXPECT(f.waitCalls == 1 && l.rawStatus() == Exit(1), "no second wait, no second status");
    // Natural exit without EOF (a descendant holds the slave): transport stays open.
    EXPECT(l.transportOpen() && !l.cleanupComplete(), "exit alone is not cleanup");
    f.reads = {Bytes("descendant")};
    l.readable(l.generation());
    EXPECT(f.ingested == "last wordsdescendant", "descendant output still read");
    f.ackReadInline = f.ackWriteInline = true;
    l.terminate();
    EXPECT(f.signals.empty(), "no signal after the child was reaped");
    EXPECT(l.cleanupComplete() && f.leakFree(), "explicit retire completes cleanup");
  }
  // 6. A signal status is raw and exact.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.ackReadInline = f.ackWriteInline = true;
    f.start(l, 10, 100); l.begin(10, 100);
    f.waits = {{100, SIGKILL, 0}};
    l.reap(l.generation());
    EXPECT(l.statusValid() && l.rawStatus() == SIGKILL, "signal status raw");
  }
  // 7. ECHILD: explicit Unknown, never a raw 0 exit.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.ackReadInline = f.ackWriteInline = true;
    f.start(l, 10, 100); l.begin(10, 100);
    f.waits = {{-1, 0, ECHILD}};
    l.reap(l.generation());
    EXPECT(l.state() == LifeState::Unknown && !l.statusValid(), "unknown state");
    EXPECT(f.log == "unknown" + std::to_string(ECHILD) + ";", "unknown, not exit: " << f.log);
    EXPECT(f.log.find("exit") == std::string::npos, "no invented exit");
    l.terminate();
    EXPECT(f.signals.empty(), "no signal once the PID is released");
    f.ownedPids.clear();  // the fake cannot reap what ECHILD says is not ours
    EXPECT(l.cleanupComplete() && f.leakFree(), "clean after retire");
  }
  // 8. terminate: HUP once to the direct PID; an ignored HUP keeps the reaper.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.ackReadInline = f.ackWriteInline = true;
    f.start(l, 10, 100); l.begin(10, 100);
    l.terminate(); l.terminate();
    EXPECT(f.signals.size() == 1 && f.signals[0].first == 100 && f.signals[0].second == SIGHUP, "one HUP to the direct child");
    EXPECT(l.state() == LifeState::Stopping && l.childPid() == 100, "still owned while stopping");
    EXPECT(f.closes == 1 && l.descriptor() == -1, "fd retired once");
    for (int i = 0; i < 20; ++i) l.reap(l.generation());  // HUP ignored
    EXPECT(l.childPid() == 100 && !l.canBegin(), "reaper kept; restart refused");
    EXPECT(!l.begin(11, 101), "begin refused while the child is owned");
    f.waits = {{100, SIGHUP, 0}};
    l.reap(l.generation());
    EXPECT(l.state() == LifeState::Exited && l.canBegin() && f.leakFree(), "reaped after HUP");
    EXPECT(f.closes == 1 && f.doubleCloses == 0, "closed exactly once");
  }
  // 9. A failed HUP (ESRCH: already a zombie) is recorded; reaping still decides.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.signalResult = ESRCH;
    f.ackReadInline = f.ackWriteInline = true;
    f.start(l, 10, 100); l.begin(10, 100);
    l.terminate();
    EXPECT(l.hangupSent() && l.hangupError() == ESRCH && l.childPid() == 100, "HUP error kept, PID kept");
    f.waits = {{100, Exit(0), 0}};
    l.reap(l.generation());
    EXPECT(f.leakFree() && l.canBegin(), "reaped");
  }
  // 10. Restart barrier: refused while either cancellation is pending, then a new generation.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, 100); l.begin(10, 100);
    const auto g1 = l.generation();
    f.waits = {{100, Exit(0), 0}};
    l.reap(g1);
    l.retireTransport();
    EXPECT(!l.begin(10, 101), "refused: no acks yet");
    l.writeCancelled(g1);
    EXPECT(!l.begin(10, 101), "refused: read ack pending");
    l.readCancelled(g1);
    EXPECT(l.canBegin() && f.leakFree(), "clean after both acks");
    f.start(l, 10, 101);  // the same descriptor number reused
    EXPECT(l.begin(10, 101), "new generation");
    const auto g2 = l.generation();
    EXPECT(g2 == g1 + 1, "generation advanced");
    // Stale callbacks from g1 change nothing in g2.
    f.reads = {Bytes("stale")};
    const int readsBefore = f.readCalls;
    l.readable(g1);
    EXPECT(f.ingested.empty() && f.readCalls == readsBefore, "stale READ ignored");
    l.reap(g1);
    EXPECT(f.waitCalls == 1, "stale reap ignored");
    l.readCancelled(g1); l.writeCancelled(g1);
    l.terminate();
    EXPECT(f.closes == 1, "stale acks do not close g2's fd");
    l.readCancelled(g2); l.writeCancelled(g2);
    EXPECT(f.closes == 2 && l.descriptor() == -1, "g2 closes on its own acks");
  }
  // 11. The writer may retire alone (write failure); the reader keeps going until EOF.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, -1); l.begin(10, -1);
    l.writeCancelled(l.generation());
    EXPECT(l.transportOpen() && f.closes == 0, "write-side retire does not close");
    f.reads = {Bytes("more"), Eof()};
    f.ackReadInline = true;
    l.readable(l.generation());
    EXPECT(f.cancelWrites == 0, "writer not cancelled twice");
    EXPECT(f.closes == 1 && f.leakFree() && l.canBegin(), "closed after the reader acks");
  }
  // 12. A read error other than EAGAIN/EINTR/EIO ends the transport with its errno.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, -1); l.begin(10, -1);
    f.reads = {Err(EBADF)};
    l.readable(l.generation());
    EXPECT(f.log.rfind("ended" + std::to_string(EBADF) + ";", 0) == 0, "error reported: " << f.log);
  }
  // 13. Reentrancy: ingest re-entering readable() does not start a second reader.
  {
    Fake f; SessionLifecycle l(f.adapter()); f.start(l, 10, -1); l.begin(10, -1);
    auto a = f.adapter();
    int nested = 0;
    SessionLifecycle *lp = nullptr;
    a.ingest = [&](const char *d, std::size_t n) { f.ingested.append(d, n); if (nested++ == 0) lp->readable(lp->generation()); };
    SessionLifecycle l2(a); lp = &l2; f.life = &l2; l2.begin(10, -1);
    f.reads = {Bytes("a"), Bytes("b")};
    l2.readable(l2.generation());
    EXPECT(f.ingested == "ab" && f.readCalls == 3, "single reader under reentry: " << f.ingested << " " << f.readCalls);
  }
  // 14. Quit wait: bounded by the deadline; reports incomplete without killing.
  {
    double clock = 0;
    int steps = 0;
    bool done = WaitForQuiescence([] { return false; }, [&] { return clock; },
                                  [&](double d) { clock += d; ++steps; }, 0.5);
    EXPECT(!done && clock <= 0.5 + 1e-9 && clock >= 0.5 - 1e-9, "stops at the deadline: " << clock);
    EXPECT(steps == 50, "10 ms steps: " << steps);
    clock = 0;
    int calls = 0;
    done = WaitForQuiescence([&] { return ++calls > 3; }, [&] { return clock; }, [&](double d) { clock += d; }, 5);
    EXPECT(done && clock < 0.05, "returns as soon as clean");
    EXPECT(WaitForQuiescence([] { return true; }, [] { return 0.0; }, [](double) {}, 0), "already clean");
  }
  // 15. Quit across sessions: a HUP-honouring child and a HUP-ignoring one.
  {
    Fake fa, fb;
    fa.ackReadInline = fa.ackWriteInline = fb.ackReadInline = fb.ackWriteInline = true;
    SessionLifecycle a(fa.adapter()), b(fb.adapter());
    fa.start(a, 10, 100); fb.start(b, 11, 200);
    a.begin(10, 100); b.begin(11, 200);
    a.terminate(); b.terminate();
    double clock = 0;
    bool done = WaitForQuiescence([&] { return a.cleanupComplete() && b.cleanupComplete(); },
                                  [&] { return clock; },
                                  [&](double d) {
                                    clock += d;
                                    if (clock > 0.1 && fa.waits.empty() && a.childPid() > 0) fa.waits = {{100, SIGHUP, 0}};
                                    a.reap(a.generation()); b.reap(b.generation());
                                  }, 1.0);
    EXPECT(!done, "incomplete reported");
    EXPECT(a.cleanupComplete() && fa.leakFree(), "a clean");
    EXPECT(!b.cleanupComplete() && b.state() == LifeState::Stopping && b.childPid() == 200, "b still stopping, still owned");
    EXPECT(fb.signals.size() == 1 && fb.signals[0].second == SIGHUP, "no escalation beyond the one HUP");
    EXPECT(fb.openFds.empty(), "b's fd retired even though its child lingers");
  }
  if (failures) { std::cerr << failures << " failure(s)\n"; return 1; }
  std::cout << "COTSessionLifecycleTests: all passed\n";
  return 0;
}
