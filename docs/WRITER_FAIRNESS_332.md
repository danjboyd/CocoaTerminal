# Bounded writer fairness correction

Requested by native owner17268 and lead17276 after their independent finite pure probe against writer A ee4815b:10000EINTR thenEAGAIN made10001synchronous adapter calls before yielding. This is deterministic source/core evidence, not a reproduced GUI/runtime hang. Separate branch operational-fairness-332 starts exactly at ee4815b5329fe9d142a9b83710e70ea42d1a6298; original observer3fe505e, writer A, accepted pure consumer78c5464 and host0fd2483 are preserved.

Native owner17342 agreed64calls/64KiB and an exclusive driver seam. Each drain turn now attempts at most64writes and admits at most64KiB of positive write progress, caps each offered write to remaining byte budget and counts EINTR as work. Remaining bytes yield to one asynchronously queued continuation. Enqueue while waiting/continuation-pending only admits FIFO data; it never starts another drain. Accepted still means whole local transaction admission, not delivery/execution.

DriverState is exactly one of Closed, Idle, WritableWaiting or ContinuationPending. Writable callbacks require matching generation AND WritableWaiting and disarm readiness before drain. Continuations require matching generation, pending state AND a unique continuation ticket; ticket checking prevents a duplicate old callback from consuming a newly scheduled turn in the same generation. EAGAIN switches exclusively to external readiness, never immediate self-rescheduling. Close clears driver state and pending data before disarm/fd retirement, increments generation and makes queued callbacks stale. The native adapter queues a generation/ticket callback on the same terminal owner through its existing non-owning session proxy; it never invokes inline. Inline/reentrant or missing schedulers fail visibly, not recursively.

Yield alone would still allow all-EINTR CPU spinning. Policy is explicit: after8consecutive full-budget turns with zero successful bytes, fail the transport visibly and cancel all admitted pending suffixes. That is at most512EINTR attempts across8turns, not10001in one call or unbounded immediate continuation. Error text states no progress and pending input cancelled. Positive byte progress resets that count. EAGAIN waits for external readiness and ends the immediate no-progress series. The caller must not retry automatically; next enqueue returns Failed until an explicit new generation is opened. This bounded failure policy is part of this source review, not a runtime-tuned operational limit.

## Deterministic evidence

Full low-priority single-job library/demo/test executable build passes. ONLY CocoaTerminalWriterTests and CocoaTerminalFairnessTests executed,2/2pass. They use fake integer descriptors/write/readiness/close and explicit fake task queues; no actual dispatch source, fd, PTY, child, SSH, clipboard, GUI or remote runtime.

Existing FIFO/immutability/backpressure/Observe/permanent-error writer cases still pass. New fairness checks cover64initial EINTR calls then yield;10000configured EINTR stops at512with explicit cancellation; recoverable100EINTR completes across turns;1byte writes yield every64calls;1MiB payload offers64KiB at most and drains in16turns; pending enqueue does not drain/double-schedule; same-generation stale tickets and duplicate idle callbacks do not write; stale readiness cannot overlap a continuation; EAGAIN->ready->budget yield->EAGAIN readiness transition; cancellation/reopen with both untouched and partially delivered old input; generation/ticket rejects on reused fake fd; close invariant visible before retirement; Observe never schedules or writes; inline/missing scheduler fails closed. Exact bytes remain FIFO, cancelled suffixes never replay.

Reproduce only pure targets:

```
ctest --test-dir <fairness-build> -R '^CocoaTerminal(Writer|Fairness)Tests$' --output-on-failure
```

## Still unproved / unchanged

No actual native dispatch scheduling/cancel lifetime proof. Proxy deallocation, kernel fd-close completion, queue fairness/timing, platform backpressure, GUI error rendering and delayed event behavior remain source-review/runtime gaps. A writable cancellation handler is NOT a read/resize quiescence or child cleanup barrier. Existing dual NSFileHandle/poll reads, blocking/double wait, raw status/PID/reaper and spawn/restart mechanics remain lifecycle B blockers. No second fd owner, B code, process-group kill, observer/host branch rewrite, app wiring, integration, merge/deploy or operational acceptance is included. Actual hold/geometry/canonical transport and independent runtime authority remain separate gates.
