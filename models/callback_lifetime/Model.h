// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <cstdint>
#include <memory>
#include <stdexcept>
namespace cot::review {
// Specification model ONLY. No Objective-C/runtime/OS code. Atomic weak load and
// final-release ordering are assumptions represented as indivisible model steps.
struct State {
  unsigned external=1, leases=0, notifications=0, accesses=0, stores=0;
  bool deallocating=false, weakAvailable=true, ownerFenced=false;
  void maybeBeginDealloc() {
    if (!external && !leases && !notifications) { deallocating=true; weakAvailable=false; }
  }
  void finalExternalRelease() { if (!external) throw std::logic_error("duplicate external release"); --external; maybeBeginDealloc(); }
  void weakPrimitiveInvalidate() { ++stores; weakAvailable=false; }
  void access() { if (deallocating || !leases) throw std::logic_error("session access without live lease"); ++accesses; }
  void retainNotification() { access(); ++notifications; }
  void deliverNotification() { if (!notifications) throw std::logic_error("missing notification ownership"); --notifications; maybeBeginDealloc(); }
};
class Lease {
  State *s_=nullptr;
 public:
  explicit Lease(State *s=nullptr):s_(s) {}
  Lease(const Lease &)=delete;
  Lease &operator=(const Lease &)=delete;
  Lease(Lease &&other) noexcept:s_(other.s_) { other.s_=nullptr; }
  ~Lease() { if (s_) { --s_->leases; s_->maybeBeginDealloc(); } }
  explicit operator bool() const { return s_!=nullptr; }
  State &get() { if (!s_) throw std::logic_error("nil lease"); return *s_; }
};
class Token {
  State *state_; // Logical weak handle, not a production assign-pointer design.
 public:
  explicit Token(State &s):state_(&s) {}
  Lease atomicWeakRetainedLoad() {
    if (state_->deallocating || !state_->weakAvailable) return Lease();
    ++state_->leases; return Lease(state_);
  }
  void invalidateThroughWeakPrimitive() { state_->weakPrimitiveInvalidate(); }
};
struct Gate {
  bool open=true;
  std::uint64_t owner=1,generation=1,ticket=1;
  bool matches(std::uint64_t o,std::uint64_t g,std::uint64_t t) const { return open && o==owner && g==generation && t==ticket; }
  void shutdown(Token &token,State &s) { open=false; ++generation; ++ticket; token.invalidateThroughWeakPrimitive(); s.ownerFenced=true; }
  void supersede() { ++owner; ++generation; ++ticket; }
};
enum class Path { Work, Cancel, CancelAfterAcquire, Error, Throw };
enum class Result { Worked, Nil, Cancelled, Stale, Error };
struct Task {
  std::shared_ptr<Token> token; // Queued block owns token through every path.
  std::uint64_t owner=1,generation=1,ticket=1;
  Path path=Path::Work;
  bool releaseExternalAfterAcquire=false, fenceAfterAcquire=false, supersedeAfterAcquire=false;
  Result run(Gate &gate) {
    if (path==Path::Cancel) return Result::Cancelled;
    Lease lease=token->atomicWeakRetainedLoad();
    if (!lease) return Result::Nil;
    if (releaseExternalAfterAcquire) lease.get().finalExternalRelease();
    if (path==Path::CancelAfterAcquire) return Result::Cancelled;
    if (fenceAfterAcquire) gate.shutdown(*token,lease.get());
    if (supersedeAfterAcquire) gate.supersede();
    if (!gate.matches(owner,generation,ticket)) return Result::Stale;
    lease.get().access();
    if (path==Path::Throw) throw std::runtime_error("synthetic callback failure");
    if (path==Path::Error) { lease.get().retainNotification(); return Result::Error; }
    return Result::Worked; // RAII lease releases AFTER last session access.
  }
};
struct Retirement {
  unsigned closes=0;
  bool cancelled=false;
  void acknowledge() { if (!cancelled) { cancelled=true; ++closes; } }
  // Deliberately owns no token/session pointer. This is not a read/fd barrier.
};
}
