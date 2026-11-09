# Pure callback ownership specification model

Finite lead18698/18726 source follow-on to completed design2276. Separate branch
from fairness24f9e6b. This directory is not in the COT library or demo build.
No production source, native dispatch, ARC/MRC bridge or lifecycle B is changed.

`Model.h` represents required atomic weak-retained load and final-release ordering
as INDIVISIBLE SPECIFICATION STEPS, not an implementation of Objective-C weak
references. Its raw C++ State pointer is a logical handle to an immortal test
record, never a proposed production assign-pointer fallback. The state records
logical dealloc start rather than destroying the record; invalid access throws.
The actual runtime's atomicity is an assumption to be tested separately, not a
conclusion from these tests. No threads, OS descriptors, Objective-C, GUI, PTY,
child, SSH, clipboard, Helpdesk or provider calls exist in this model.

Move-only RAII leases represent retained ownership through all accesses, including
normal/error/exception/stale and post-acquire cancellation. Queued tasks own a
shared token independent of session ownership. Runtime final release marks weak
acquisition unavailable before a later owner fence. Owner shutdown invalidates
through a named abstract weak primitive and closes generation/ticket/owner gates.
This models no automatic task replay or target activation. A separate retirement
record owns no session/token and acknowledges close once; it is not a shared
READ/WRITE cancellation or child-cleanup implementation.

The single deterministic test executable checks acquisition before final release,
final release before acquire with dealloc paused before owner fence, cancellation
before/after acquisition, exception/error notification ownership, every-path lease
balance, shutdown/supersession between acquire and guard, stale owner/generation/
ticket, queued token lifetime after session death, nil error path after dealloc,
and idempotent session-free late retirement. Already-owned leases can safely do
cleanup access after invalidation, but work still requires an open matching gate.

Build/run with the existing compiler, low priority, into a scratch output path:

```
clang++ -std=c++17 -Wall -Wextra -Werror ModelTests.cpp -o <scratch>/model-tests
<scratch>/model-tests
```

Owner run passes with exit0 (log361-model-tests.log). This certifies only the
sequential assumed-atomic model and its exercised traces. It does NOT certify
native runtime weak atomicity, compiler/ABI ownership, macOS support, libdispatch
lifetime or actual deallocation. Unsupported or unverified runtime remains
unavailable; no production callback transport can be enabled from these results.

## Platform matrix at this task boundary

| Dimension | Existing evidence | Status / gate |
|---|---|---|
| GNUstep COT baseline | Existing build metadata: clang/clang++, gnustep-2.2 runtime flag, MRC COT units | Prior compilation only; no new bridge or loaded-runtime proof |
| GNUstep weak API surface | Installed objc-arc.h declarations and static libobjc.so.4.6 exported weak symbols read earlier | Declaration/export evidence, NOT actual weak/final-release atomicity |
| ARC-to-MRC retained return | Proposed explicit NS_RETURNS_RETAINED copySession with MRC release after last access | Not implemented/compiled/probed |
| Current loaded runtime + synthetic weak probe | Same approval5446 not visible to this executing session when checked | HELD pending authenticated existing-answer delivery; no probe run |
| macOS deployment floor/runtime | No current pinned Apple toolchain or target evidence supplied | Unknown/unsupported for integration, no claim |
| Native callback/source/fd/read/child lifetime | Source design only; B excluded | Unverified; no integration/runtime go |

Original callback design76caa0d... and addendum6e4302de... remain the design inputs.
The old305 operational acceptance items stay pending. Goal361 was actually
returned as day2026-11-09/statusproposed, not an approved next-day tracking record.
No second proposal/backdating/global-hours mutation is performed by this model.
