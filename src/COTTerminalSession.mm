// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalSession.h>

#import "COTTerminalSessionInternal.h"

#include "COTTerminalGrid.h"
#include "COTTransportWriter.h"
#include "COTSessionLifecycle.h"
#include "COTSpawnPlan.h"

#import <dispatch/dispatch.h>

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>

#include <algorithm>
#if defined(__APPLE__)
#include <crt_externs.h>
#define COTEnviron (*_NSGetEnviron())
#else
extern char **environ;
#define COTEnviron environ
#endif

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

#if defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__)
#include <pty.h>
#endif

static char COTTerminalOwnerKey;
@interface COTWriterTarget : NSObject
@property(nonatomic, assign) COTTerminalSession *session;
@end
@implementation COTWriterTarget
@synthesize session;
@end

// Patch B (goal 685): the lifecycle core plus its native sources. Shared by the
// session and by its dispatch handlers, so an owned child is still reaped, and
// the fd still closed after both cancellations, if the session goes first. All
// fields except `clean` are confined to the terminal serial owner.
struct COTLifecycleNative {
  std::unique_ptr<cot::SessionLifecycle> life;
  dispatch_queue_t queue;
  dispatch_source_t read = NULL;
  dispatch_source_t reaper = NULL;
  bool writeAckPending = false;
  COTWriterTarget *target;
  std::atomic<bool> clean{true};
  COTLifecycleNative(dispatch_queue_t q, COTWriterTarget *t) : queue(q), target([t retain]) { dispatch_retain(queue); }
  ~COTLifecycleNative() { [target release]; dispatch_release(queue); }
};

// Live lifecycles, for +shutdownAllSessionsWithTimeout:. An expired entry has
// released every source, so it owns no fd, child or pending cancellation.
static std::mutex COTLifecycleRegistryLock;
static std::vector<std::weak_ptr<COTLifecycleNative>> &COTLifecycleRegistry() {
  static std::vector<std::weak_ptr<COTLifecycleNative>> registry;
  return registry;
}
// The startup pipe must not leak into the child's exec'd program: close-on-exec.
// Linux/BSD set it atomically; elsewhere fcntl right after pipe.
static BOOL COTCloseOnExecPipe(int fds[2]) {
#if defined(__linux__) || defined(__FreeBSD__)
  return pipe2(fds, O_CLOEXEC) == 0;
#else
  if (pipe(fds) != 0) return NO;
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0) {
    close(fds[0]); close(fds[1]); return NO;
  }
  return YES;
#endif
}
static double COTMonotonicSeconds() {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static NSString *const COTTerminalErrorDomain = @"COTTerminalErrorDomain";
static NSUInteger const COTTerminalMaximumColumns = 1000;
static NSUInteger const COTTerminalMaximumRows = 1000;

@implementation COTTerminalSnapshot

- (void)dealloc {
  [title release];
  [super dealloc];
}

@end

static NSDictionary *COTDictionaryFromColor(const cot::TerminalColor &color) {
  if (color.kind == cot::TerminalColor::Kind::Default) {
    return [NSDictionary dictionaryWithObject:@"default" forKey:@"kind"];
  }
  if (color.kind == cot::TerminalColor::Kind::Palette) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
      @"palette", @"kind",
      [NSNumber numberWithInt:color.index], @"index",
      nil];
  }
  return [NSDictionary dictionaryWithObjectsAndKeys:
    @"rgb", @"kind",
    [NSNumber numberWithInt:color.red], @"red",
    [NSNumber numberWithInt:color.green], @"green",
    [NSNumber numberWithInt:color.blue], @"blue",
    nil];
}

// What main-thread callbacks hold instead of the session. The session clears it at the start of -dealloc (on the main
// thread), so a callback queued while the session was being freed finds nil and does nothing.
@interface COTSessionHandle : NSObject {
@public
  COTTerminalSession *session;  // not retained
}
@end
@implementation COTSessionHandle
@end

@interface COTTerminalSession () {
  COTSessionHandle *_handle;
  COTTerminalConfiguration *_configuration;
  cot::TerminalGrid *_grid;
  cot::TransportWriter *_writer;
  dispatch_source_t _writeSource;
  BOOL _writeSourceResumed;
  std::uint64_t _writerSourceGeneration;
  COTWriterTarget *_writerTarget;
  NSString *_transportError;
  int _masterFd;
  pid_t _childPid;
  BOOL _running;
  BOOL _allowsInput;
  BOOL _fixedGrid;
  NSUInteger _columns;
  NSUInteger _rows;
  std::shared_ptr<COTLifecycleNative> *_native;
  std::uint64_t _lifeGeneration;
  NSString *_lastClipboardWrite;
  NSUInteger _clipboardWriteCount;
  dispatch_queue_t _terminalQueue;
  NSLock *_snapshotLock;
  COTTerminalSnapshot *_snapshot;
  BOOL _resizeOperationScheduled;
  NSUInteger _pendingColumns;
  NSUInteger _pendingRows;
  BOOL _perfLoggingEnabled;
  NSTimeInterval _perfLastLogTime;
  NSUInteger _perfReadNotifications;
  NSUInteger _perfBytesRead;
  NSUInteger _perfIngests;
  NSUInteger _perfPublishes;
  NSUInteger _perfDirtyRows;
  NSUInteger _perfFullRedraws;
}
@end

@implementation COTTerminalSession

- (COTTerminalSnapshot *)snapshotFromGrid {
  COTTerminalSnapshot *snapshot = [[COTTerminalSnapshot alloc] init];
  snapshot->columns = _grid->columns();
  snapshot->rows = _grid->rows();
  snapshot->cursorColumn = _grid->cursorColumn();
  snapshot->cursorRow = _grid->cursorRow();
  snapshot->cursorVisible = _grid->cursorVisible();
  snapshot->usingAlternateScreen = _grid->usingAlternateScreen();
  snapshot->hasUsedAlternateScreen = _grid->hasUsedAlternateScreen();
  snapshot->hasColorSpans = _grid->hasColorSpans();
  snapshot->hasUnicode = _grid->hasUnicode();
  snapshot->mouseReportingEnabled = _grid->mouseReportingEnabled();
  snapshot->mouseButtonMotionReportingEnabled = _grid->mouseButtonMotionReportingEnabled();
  snapshot->mouseAnyMotionReportingEnabled = _grid->mouseAnyMotionReportingEnabled();
  snapshot->sgrMouseModeEnabled = _grid->sgrMouseModeEnabled();
  snapshot->alternateScrollModeEnabled = _grid->alternateScrollModeEnabled();
  snapshot->bracketedPasteEnabled = _grid->bracketedPasteEnabled();
  snapshot->focusReportingEnabled = _grid->focusReportingEnabled();
  snapshot->scrollbackLineCount = _grid->scrollbackLineCount();
  snapshot->viewportOffset = _grid->viewportOffset();
  snapshot->maxViewportOffset = _grid->maxViewportOffset();
  snapshot->fullRedraw = _grid->fullRedrawPending();
  _grid->getAndClearDirtyRows(snapshot->dirtyRows);
  _grid->clearFullRedrawPending();
  if (_grid->viewportOffset() == 0) {
    snapshot->cells = _grid->visibleCells();
    snapshot->lines = _grid->visibleLines();
  } else {
    snapshot->cells = _grid->viewportCells();
    snapshot->lines = _grid->viewportLines();
  }
  std::string title = _grid->title();
  if (!title.empty()) {
    snapshot->title = [[NSString alloc] initWithBytes:title.data()
                                              length:title.size()
                                            encoding:NSUTF8StringEncoding];
  }
  if (snapshot->title == nil) {
    snapshot->title = [@"" copy];
  }
  return [snapshot autorelease];
}

// Main-thread callbacks reach the session through its handle, never through a retain of self. -dealloc waits on the
// terminal queue (dispatch_sync); a block running there in the meantime used to [self retain] a session whose dealloc
// had begun, and its main-thread block then ran on freed memory once dealloc finished.
- (void)deliverOnMain:(void (^)(COTTerminalSession *session))block {
  COTSessionHandle *handle = [_handle retain];
  void (^copied)(COTTerminalSession *) = [block copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    COTTerminalSession *session = handle->session;
    if (session != nil) copied(session);
    [copied release];
    [handle release];
  });
}

- (void)publishSnapshotAndNotify:(BOOL)notify {
  COTTerminalSnapshot *snapshot = [[self snapshotFromGrid] retain];
  [self recordPerfPublishWithSnapshot:snapshot];
  [_snapshotLock lock];
  [_snapshot release];
  _snapshot = snapshot;
  [_snapshotLock unlock];
  if (!notify) {
    return;
  }
  [self deliverOnMain:^(COTTerminalSession *session) {
    id<COTTerminalDelegate> delegate = [[session delegate] retain];
    if ([delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
      [delegate terminalSessionDidUpdateScreen:session];
    }
    [delegate release];
  }];
}

- (void)performGridMutation:(dispatch_block_t)block notify:(BOOL)notify {
  dispatch_async(_terminalQueue, ^{
    if (_grid == NULL) {
      return;
    }
    block();
    [self publishSnapshotAndNotify:notify];
  });
}

- (instancetype)initWithConfiguration:(COTTerminalConfiguration *)configuration {
  self = [super init];
  if (self) {
    _masterFd = -1;
    _childPid = -1;
    _configuration = [configuration copy];
    if (_configuration == nil ||
        (_configuration.inputPolicy != COTTerminalInputPolicyInteractive &&
         _configuration.inputPolicy != COTTerminalInputPolicyObserve) ||
        (_configuration.sizingPolicy != COTTerminalSizingPolicyFollowView &&
         _configuration.sizingPolicy != COTTerminalSizingPolicyFixedGrid) ||
        _configuration.initialColumns < 1 || _configuration.initialColumns > COTTerminalMaximumColumns ||
        _configuration.initialRows < 1 || _configuration.initialRows > COTTerminalMaximumRows) {
      [self release];
      return nil;
    }
    _allowsInput = _configuration.inputPolicy == COTTerminalInputPolicyInteractive;
    _fixedGrid = _configuration.sizingPolicy == COTTerminalSizingPolicyFixedGrid;
    _columns = _configuration.initialColumns;
    _rows = _configuration.initialRows;
    _grid = new cot::TerminalGrid(_columns, _rows);
    _grid->setScrollbackLimit([_configuration scrollbackLineLimit]);
    COTTerminalSession *unsafeSelf = self;
    _grid->setOutputCallback([unsafeSelf](const char *bytes, std::size_t length) {
      [unsafeSelf writeReplyBytes:bytes length:length];
    });
    _grid->setTitleCallback([unsafeSelf](const std::string &title) {
      [unsafeSelf deliverTitle:title];
    });
    _grid->setBellCallback([unsafeSelf]() {
      [unsafeSelf deliverBell];
    });
    _grid->setClipboardWriteCallback([unsafeSelf](const std::string &data) {
      [unsafeSelf deliverClipboardWrite:data];
    });
    _grid->setClipboardReadCallback([unsafeSelf]() -> std::string {
      return [unsafeSelf readClipboardForRemote];
    });
    _masterFd = -1;
    _childPid = -1;
    _running = NO;
    _terminalQueue = dispatch_queue_create("org.cocoaterminal.session", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_terminalQueue, &COTTerminalOwnerKey, self, NULL);
    _writerTarget = [[COTWriterTarget alloc] init];
    _writerTarget.session = self;
    _native = new std::shared_ptr<COTLifecycleNative>(std::make_shared<COTLifecycleNative>(_terminalQueue, _writerTarget));
    (*_native)->life.reset(new cot::SessionLifecycle([self lifecycleAdapter:_native->get()]));
    COTTerminalSession *writerSelf = self;
    _writer = new cot::TransportWriter({
      [](int fd, const char *bytes, std::size_t length) -> cot::WriteResult {
        ssize_t count = write(fd, bytes, length);
        return {count, count < 0 ? errno : 0};
      },
      [writerSelf](int, std::uint64_t) { [writerSelf setWritableEnabled:YES]; },
      [writerSelf]() { [writerSelf setWritableEnabled:NO]; },
      [writerSelf](int fd) { [writerSelf retireWriterDescriptor:fd]; },
      [writerSelf](std::uint64_t generation, std::uint64_t ticket) {
        [writerSelf scheduleWriterContinuation:generation ticket:ticket];
      }
    });
    _snapshotLock = [[NSLock alloc] init];
    _handle = [[COTSessionHandle alloc] init];
    _handle->session = self;
    _perfLoggingEnabled = getenv("COCOATERMINAL_PERF_LOG") != NULL;
    _perfLastLogTime = [NSDate timeIntervalSinceReferenceDate];
    [self publishSnapshotAndNotify:NO];
  }
  return self;
}

- (void)recordPerfReadWithByteCount:(NSUInteger)byteCount {
  if (!_perfLoggingEnabled) {
    return;
  }
  _perfReadNotifications += 1;
  _perfBytesRead += byteCount;
}

- (void)recordPerfIngest {
  if (_perfLoggingEnabled) {
    _perfIngests += 1;
  }
}

- (void)recordPerfPublishWithSnapshot:(COTTerminalSnapshot *)snapshot {
  if (!_perfLoggingEnabled) {
    return;
  }
  _perfPublishes += 1;
  if (snapshot->fullRedraw) {
    _perfFullRedraws += 1;
  }
  for (bool dirty : snapshot->dirtyRows) {
    if (dirty) {
      _perfDirtyRows += 1;
    }
  }
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (now - _perfLastLogTime >= 1.0) {
    fprintf(stderr,
            "[CocoaTerminal session perf] reads=%lu bytes=%lu ingests=%lu publishes=%lu dirtyRows=%lu fullRedraws=%lu\n",
            (unsigned long)_perfReadNotifications,
            (unsigned long)_perfBytesRead,
            (unsigned long)_perfIngests,
            (unsigned long)_perfPublishes,
            (unsigned long)_perfDirtyRows,
            (unsigned long)_perfFullRedraws);
    fflush(stderr);
    _perfReadNotifications = 0;
    _perfBytesRead = 0;
    _perfIngests = 0;
    _perfPublishes = 0;
    _perfDirtyRows = 0;
    _perfFullRedraws = 0;
    _perfLastLogTime = now;
  }
}

// These methods execute on the terminal serial owner, including close and
// readiness events. The separate read/child lifecycle still needs patch B.
- (void)withTransportOwner:(dispatch_block_t)block {
  if (dispatch_get_specific(&COTTerminalOwnerKey) == self) block();
  else dispatch_sync(_terminalQueue, block);
}
- (void)setWritableEnabled:(BOOL)enabled {
  // The WRITE source is created lazily, on the first EAGAIN of a generation.
  // A source that is created up front but never armed must be resumed just to
  // be cancelled, and doing that while a PTY hang-up floods the shared fd
  // crashed the GNUstep libdispatch epoll manager (_dispatch_event_merge_hangup,
  // reproduced natively in goal 693). Most sessions never arm it at all.
  if (enabled && !_writeSource) {
    const int fd = _writer ? _writer->descriptor() : -1;
    dispatch_source_t source = fd >= 0 ? dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, fd, 0, _terminalQueue) : NULL;
    if (!source) {
      [self recordTransportError:@"Terminal writable-readiness setup failed."];
      COTWriterTarget *target = _writerTarget;
      dispatch_async(_terminalQueue, ^{ [target.session closeWriterAfterReadinessFailure:_writerSourceGeneration]; });
      return;
    }
    const std::uint64_t generation = _writerSourceGeneration;
    COTWriterTarget *target = _writerTarget;
    dispatch_source_set_event_handler(source, ^{ [target.session writerWritable:generation]; });
    _writeSource = source;
    _writeSourceResumed = NO;
  }
  if (!_writeSource || enabled == _writeSourceResumed) return;
  if (enabled) dispatch_resume(_writeSource); else dispatch_suspend(_writeSource);
  _writeSourceResumed = enabled;
}
- (void)closeWriterAfterReadinessFailure:(std::uint64_t)generation {
  if (_writer && _writer->generation() == generation && _writer->descriptor() >= 0) _writer->close();
}
// Retired dispatch sources are released with dispatch_release unconditionally:
// this library is built without ARC (manual retain/release throughout), where
// dispatch_release is valid whether or not dispatch objects are Objective-C
// objects (OS_OBJECT_USE_OBJC). The previous #if !OS_OBJECT_USE_OBJC guard
// leaked every retired source on Apple platforms. Do not build this file as ARC.
// The writer is done with the descriptor. Patch B: it no longer closes it; its
// WRITE source's cancellation acknowledges to the lifecycle, which closes the fd
// once, after the READ source has acknowledged too.
- (void)retireWriterDescriptor:(int)fd {
  (void)fd;
  std::shared_ptr<COTLifecycleNative> native = *_native;
  const std::uint64_t generation = _lifeGeneration;
  if (_writeSource) {
    dispatch_source_t source = _writeSource;
    _writeSource = NULL;
    native->writeAckPending = true;
    dispatch_source_set_cancel_handler(source, ^{
      native->writeAckPending = false;
      native->life->writeCancelled(generation);
    });
    dispatch_source_cancel(source);
    if (!_writeSourceResumed) dispatch_resume(source);
    _writeSourceResumed = NO;
    dispatch_release(source);
  } else native->life->writeCancelled(generation);
}
// cancelWrite from the lifecycle: close the writer, or acknowledge if it is
// already closed and no WRITE-source cancellation is still on its way.
- (void)lifecycleCancelWrite {
  COTLifecycleNative *native = _native->get();
  if (_writer && _writer->descriptor() >= 0) _writer->close();
  else if (!native->writeAckPending) native->life->writeCancelled(_lifeGeneration);
}
- (void)lifecycleIngest:(const char *)bytes length:(std::size_t)length {
  if (_grid == NULL) return;
  [self recordPerfReadWithByteCount:(NSUInteger)length];
  [self recordPerfIngest];
  _grid->ingest(bytes, length);
  [self publishSnapshotAndNotify:YES];
}
- (void)lifecycleExited:(int)status {
  _running = NO;
  COTTerminalSession *session = [self retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    id<COTTerminalDelegate> delegate = [session delegate];
    if ([delegate respondsToSelector:@selector(terminalSession:didExitWithStatus:)])
      [delegate terminalSession:session didExitWithStatus:status];
    [session release];
  });
}
- (void)lifecycleLostChild:(int)errorNumber {
  _running = NO;
  [self recordTransportError:[NSString stringWithFormat:@"Child exit status unavailable: %s", strerror(errorNumber)]];
  COTTerminalSession *session = [self retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    id<COTTerminalDelegate> delegate = [session delegate];
    if ([delegate respondsToSelector:@selector(terminalSession:didLoseChildWithError:)])
      [delegate terminalSession:session didLoseChildWithError:errorNumber];
    [session release];
  });
}
- (cot::SessionLifecycle::Adapter)lifecycleAdapter:(COTLifecycleNative *)native {
  // `native` owns the core that owns these closures, so a raw pointer is safe.
  // Session work goes through the target, which dealloc clears on this owner.
  cot::SessionLifecycle::Adapter a;
  a.read = [](int fd, char *buffer, std::size_t length) -> cot::IOResult {
    ssize_t count = read(fd, buffer, length);
    return {count, count < 0 ? errno : 0};
  };
  a.ingest = [native](const char *bytes, std::size_t length) {
    [native->target.session lifecycleIngest:bytes length:length];
  };
  a.waitNoHang = [](int pid) -> cot::WaitResult {
    int status = 0;
    pid_t result = waitpid(pid, &status, WNOHANG);
    return {(int)result, status, result < 0 ? errno : 0};
  };
  a.signal = [](int pid, int signalNumber) -> int { return kill(pid, signalNumber) == 0 ? 0 : errno; };
  a.cancelRead = [native]() {
    COTTerminalSession *session = native->target.session;
    if (session) session->_masterFd = -1;  // The borrowed alias dies first.
    if (native->read) {
      dispatch_source_t source = native->read;
      native->read = NULL;
      dispatch_source_cancel(source);  // Its cancel handler acknowledges.
      dispatch_release(source);
    } else native->life->readCancelled(native->life->generation());
  };
  a.cancelWrite = [native]() {
    COTTerminalSession *session = native->target.session;
    if (session) [session lifecycleCancelWrite];
    else if (!native->writeAckPending) native->life->writeCancelled(native->life->generation());
  };
  a.close = [](int fd) { close(fd); };
  a.stopReaper = [native]() {
    if (!native->reaper) return;
    dispatch_source_t source = native->reaper;
    native->reaper = NULL;
    dispatch_source_cancel(source);
    dispatch_release(source);
  };
  a.exited = [native](int status) { [native->target.session lifecycleExited:status]; };
  a.unknown = [native](int errorNumber) { [native->target.session lifecycleLostChild:errorNumber]; };
  a.transportEnded = [native](int errorNumber) {
    if (errorNumber != 0)
      [native->target.session recordTransportError:[NSString stringWithFormat:@"Terminal read failed: %s", strerror(errorNumber)]];
  };
  a.cleanupComplete = [native]() { native->clean.store(true); };
  return a;
}
// Begins a lifecycle generation for `master` and `pid` on the owner, adopts the
// writer, then starts the ONE reader and the reaper. On failure everything the
// generation took is retired and the child stays owned until reaped.
- (BOOL)beginTransport:(int)master pid:(pid_t)pid error:(NSString **)problem {
  __block BOOL ok = NO;
  __block NSString *failure = nil;
  std::shared_ptr<COTLifecycleNative> native = *_native;
  [self withTransportOwner:^{
    if (!native->life->begin(master, (int)pid)) { failure = @"Previous transport cleanup is required before restart."; return; }
    native->clean.store(false);
    _lifeGeneration = native->life->generation();
    const std::uint64_t generation = _lifeGeneration;
    if (pid > 0) {
      dispatch_source_t reaper = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _terminalQueue);
      if (reaper) {
        dispatch_source_set_timer(reaper, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(reaper, ^{ native->life->reap(generation); });
        native->reaper = reaper;
        dispatch_resume(reaper);
      }
    }
    if (![self adoptTransportDescriptorOnOwner:master]) {
      failure = @"Terminal writable-readiness setup failed.";
      native->life->terminate();
      return;
    }
    dispatch_source_t reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, master, 0, _terminalQueue);
    if (!reader) {
      failure = @"Terminal read-readiness setup failed.";
      native->life->terminate();
      return;
    }
    dispatch_source_set_event_handler(reader, ^{ native->life->readable(generation); });
    dispatch_source_set_cancel_handler(reader, ^{ native->life->readCancelled(generation); });
    native->read = reader;
    dispatch_resume(reader);
    ok = YES;
  }];
  if (ok) {
    std::lock_guard<std::mutex> lock(COTLifecycleRegistryLock);
    auto &registry = COTLifecycleRegistry();
    registry.erase(std::remove_if(registry.begin(), registry.end(),
                                  [](const std::weak_ptr<COTLifecycleNative> &e) { return e.expired(); }),
                   registry.end());
    bool present = false;
    for (auto &entry : registry) if (entry.lock() == native) present = true;
    if (!present) registry.push_back(native);
  }
  if (problem) *problem = failure;
  return ok;
}
- (BOOL)isCleanupComplete {
  return (*_native)->clean.load();
}
+ (NSUInteger)shutdownAllSessionsWithTimeout:(NSTimeInterval)timeout {
  std::vector<std::shared_ptr<COTLifecycleNative>> live;
  {
    std::lock_guard<std::mutex> lock(COTLifecycleRegistryLock);
    for (auto &entry : COTLifecycleRegistry()) if (auto native = entry.lock()) live.push_back(native);
  }
  for (auto &native : live) {
    std::shared_ptr<COTLifecycleNative> owned = native;
    dispatch_async(native->queue, ^{
      COTTerminalSession *session = owned->target.session;
      if (session) session->_running = NO;
      owned->life->terminate();
    });
  }
  cot::WaitForQuiescence(
    [&live]() { for (auto &native : live) if (!native->clean.load()) return false; return true; },
    []() { return COTMonotonicSeconds(); },
    [](double seconds) { usleep((useconds_t)(seconds * 1e6)); },
    timeout);
  NSUInteger incomplete = 0;
  for (auto &native : live) if (!native->clean.load()) ++incomplete;
  return incomplete;
}
- (void)recordTransportError:(NSString *)message {
  if ((_transportError == nil && message == nil) || [_transportError isEqual:message]) return;
  [_transportError release]; _transportError = [message copy];
  COTTerminalSession *session = [self retain];
  NSString *owned = [message copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    id<COTTerminalDelegate> delegate = [session delegate];
    if (owned && [delegate respondsToSelector:@selector(terminalSession:didEncounterTransportError:)])
      [delegate terminalSession:session didEncounterTransportError:owned];
    if ([delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)])
      [delegate terminalSessionDidUpdateScreen:session];
    [owned release]; [session release];
  });
}
// Test/output-only seam: an fd-only lifecycle generation (no child, no reader)
// so the lifecycle remains the descriptor's single closer.
- (BOOL)adoptTransportDescriptor:(int)descriptor {
  __block BOOL adopted = NO;
  std::shared_ptr<COTLifecycleNative> native = *_native;
  [self withTransportOwner:^{
    if (!native->life->begin(descriptor, -1)) return;
    native->clean.store(false);
    _lifeGeneration = native->life->generation();
    adopted = [self adoptTransportDescriptorOnOwner:descriptor];
    if (!adopted) native->life->terminate();
  }];
  return adopted;
}
- (BOOL)adoptTransportDescriptorOnOwner:(int)descriptor {
  __block BOOL adopted = NO;
  ^{
    if (!_writer->open(descriptor, _allowsInput)) return;
    _masterFd = descriptor;
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
      _writer->close();
      [self recordTransportError:@"Terminal nonblocking transport setup failed."];
      return;
    }
    _writerSourceGeneration = _writer->generation();  // its WRITE source is made on first EAGAIN
    _writeSource = NULL;
    _writeSourceResumed = NO;
    [self recordTransportError:nil];
    adopted = YES;
  }();
  return adopted;
}
- (void)scheduleWriterContinuation:(std::uint64_t)generation ticket:(std::uint64_t)ticket {
  COTWriterTarget *target = _writerTarget;
  dispatch_async(_terminalQueue, ^{ [target.session writerContinue:generation ticket:ticket]; });
}
- (void)writerContinue:(std::uint64_t)generation ticket:(std::uint64_t)ticket {
  _writer->resume(generation, ticket);
  if (!_writer->error().empty())
    [self recordTransportError:[NSString stringWithUTF8String:_writer->error().c_str()]];
}
- (void)writerWritable:(std::uint64_t)generation {
  _writer->writable(generation);
  if (!_writer->error().empty())
    [self recordTransportError:[NSString stringWithUTF8String:_writer->error().c_str()]];
}
- (COTTerminalEnqueueResult)enqueueOnOwner:(NSData *)data {
  // Frozen Observe gate is duplicated by the writer's final drain policy.
  cot::EnqueueResult result = !_allowsInput ? cot::EnqueueResult::Closed :
    _writer->enqueue((const char *)[data bytes], [data length]);
  NSString *message = nil;
  if (!_writer->error().empty()) message = [NSString stringWithUTF8String:_writer->error().c_str()];
  else if (result == cot::EnqueueResult::Backpressured) message = @"Terminal input queue is full; transaction was not accepted.";
  else if (result == cot::EnqueueResult::Closed) message = @"Terminal input is closed or watching-only; transaction was not accepted.";
  else if (result == cot::EnqueueResult::Failed) message = @"Terminal transport failed; transaction was not accepted.";
  [self recordTransportError:message];
  switch (result) {
    case cot::EnqueueResult::Accepted: return COTTerminalEnqueueAccepted;
    case cot::EnqueueResult::Backpressured: return COTTerminalEnqueueBackpressured;
    case cot::EnqueueResult::Closed: return COTTerminalEnqueueClosed;
    case cot::EnqueueResult::Failed: return COTTerminalEnqueueFailed;
  }
}
- (void)writeReplyBytes:(const char *)bytes length:(std::size_t)length {
  if (!_allowsInput) return;
  NSData *data = [NSData dataWithBytes:bytes length:length];
  [self withTransportOwner:^{ [self enqueueOnOwner:data]; }];
}

- (void)deliverTitle:(const std::string &)title {
  NSString *value = [[[NSString alloc] initWithBytes:title.data()
                                              length:title.size()
                                            encoding:NSUTF8StringEncoding] autorelease];
  if (value == nil) {
    value = @"";
  }
  NSString *ownedValue = [value copy];  // the copied block keeps its own reference
  [self deliverOnMain:^(COTTerminalSession *session) {
    id<COTTerminalDelegate> delegate = [[session delegate] retain];
    if ([delegate respondsToSelector:@selector(terminalSession:didChangeTitle:)]) {
      [delegate terminalSession:session didChangeTitle:ownedValue];
    }
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:ownedValue forKey:@"title"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"COTTerminalSessionTitleDidChangeNotification"
                                                        object:session
                                                      userInfo:userInfo];
    [delegate release];
  }];
  [ownedValue release];
}

- (void)deliverBell {
  [self deliverOnMain:^(COTTerminalSession *session) {
    id<COTTerminalDelegate> delegate = [[session delegate] retain];
    if ([delegate respondsToSelector:@selector(terminalSessionDidRequestBell:)]) {
      [delegate terminalSessionDidRequestBell:session];
    }
    [delegate release];
  }];
}

- (void)deliverClipboardWrite:(const std::string &)data {
  if (!_allowsInput) return;
  NSString *text = [[[NSString alloc] initWithBytes:data.data()
                                              length:data.size()
                                            encoding:NSUTF8StringEncoding] autorelease];
  if (text == nil) {
    text = @"";
  }
  _lastClipboardWrite = [text copy];
  _clipboardWriteCount += 1;
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  @try {
    [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pasteboard setString:text forType:NSStringPboardType];
  } @catch (NSException *exception) {
    // Pasteboard server may be unavailable on headless GNUstep; the write
    // is still observable via lastClipboardWrite.
    (void)exception;
  }
  NSDictionary *userInfo = [NSDictionary dictionaryWithObject:text forKey:@"text"];
  [[NSNotificationCenter defaultCenter] postNotificationName:@"COTTerminalSessionClipboardDidWriteNotification"
                                                      object:self
                                                    userInfo:userInfo];
}

- (std::string)readClipboardForRemote {
  if (!_allowsInput) return std::string();
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  NSString *value = nil;
  @try {
    value = [pasteboard stringForType:NSStringPboardType];
  } @catch (NSException *exception) {
    (void)exception;
    value = nil;
  }
  if ([value length] == 0) {
    return std::string();
  }
  const char *utf8 = [value UTF8String];
  if (utf8 == NULL) {
    return std::string();
  }
  return std::string(utf8);
}

- (instancetype)init {
  return [self initWithConfiguration:[COTTerminalConfiguration defaultConfiguration]];
}

- (void)dealloc {
  _handle->session = nil;  // first: anything queued for the main thread now finds nothing
  // HUP once and retire; the shared lifecycle keeps reaping after we are gone.
  [self terminate];
  if (_terminalQueue != NULL) [self withTransportOwner:^{
    _writerTarget.session = nil;
    delete _writer; _writer = NULL;
    delete _grid;
    _grid = NULL;
  }];
  delete _native; _native = NULL;
  [_writerTarget release];
  [_transportError release];
  [_configuration release];
  [_snapshotLock release];
  [_snapshot release];
  [_lastClipboardWrite release];
  [_handle release];
  [super dealloc];
}

- (BOOL)startWithError:(NSError **)error {
  if (_running) {
    return YES;
  }

#if defined(_WIN32)
  if (error != NULL) {
    *error = [NSError errorWithDomain:COTTerminalErrorDomain
                                 code:2
                             userInfo:@{NSLocalizedDescriptionKey: @"Windows ConPTY support is planned but not implemented yet."}];
  }
  return NO;
#else
  __block BOOL clean = NO;
  [self withTransportOwner:^{ clean = (*_native)->life->canBegin(); }];
  if (!clean) {
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:3
      userInfo:@{NSLocalizedDescriptionKey:@"Previous transport cleanup is required before restart."}];
    return NO;
  }
  struct winsize size;
  size.ws_col = (unsigned short)_columns;
  size.ws_row = (unsigned short)_rows;
  size.ws_xpixel = 0;
  size.ws_ypixel = 0;

  // Prereq F: everything the child needs is built here, before fork. The child
  // then runs only chdir/execve/write/_exit (cot::SpawnPlan::execInChild).
  NSArray<NSString *> *command = _configuration.shellCommand;
  std::vector<std::string> argv;
  for (NSString *argument in command) argv.push_back([argument fileSystemRepresentation]);
  if (argv.empty()) argv.push_back("/bin/sh");  // as before: an empty command ran /bin/sh
  std::vector<std::string> inherited;
  for (char **entry = COTEnviron; entry && *entry; ++entry) inherited.push_back(*entry);
  std::vector<std::pair<std::string, std::string>> overrides;
  NSDictionary<NSString *, NSString *> *environment = _configuration.environment;
  for (NSString *key in [[environment allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *value = [environment objectForKey:key];
    if ([key length] > 0 && value != nil) overrides.push_back({[key UTF8String], [value UTF8String]});
  }
  if ([_configuration.terminalType length] > 0) overrides.push_back({"TERM", [_configuration.terminalType UTF8String]});
  overrides.push_back({"COLORTERM", "truecolor"});
  std::string cwd = [_configuration.workingDirectory length] > 0 ? [_configuration.workingDirectory fileSystemRepresentation] : "";
  cot::SpawnPlan plan = cot::SpawnPlan::Make(argv, inherited, overrides, cwd);
  if (!plan.ok()) {
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:5
      userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:plan.problem().c_str()]}];
    return NO;
  }
  int startup[2] = {-1, -1};
  if (!COTCloseOnExecPipe(startup)) {
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:1
      userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Startup pipe failed: %s", strerror(errno)]}];
    return NO;
  }

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &size);
  if (pid < 0) {
    const int forkError = errno;
    close(startup[0]); close(startup[1]);
    if (error != NULL) {
      NSString *message = [NSString stringWithFormat:@"forkpty failed: %s", strerror(forkError)];
      *error = [NSError errorWithDomain:COTTerminalErrorDomain
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
  }

  if (pid == 0) {
    close(startup[0]);
    plan.execInChild(startup[1]);  // [[noreturn]]
  }

  close(startup[1]);
  cot::SpawnFailure failure{0, 0};
  // Bounded: EOF arrives as soon as execve succeeds; never wait more than 2 s.
  const cot::SpawnRead startupResult = cot::ReadSpawnFailure(startup[0], 2000, failure);
  close(startup[0]);

  _childPid = pid;  // Informational; the lifecycle owns the PID until reaped.
  NSString *problem = nil;
  if (![self beginTransport:master pid:pid error:&problem]) {
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:4
      userInfo:@{NSLocalizedDescriptionKey:problem ?: @"Terminal transport setup failed."}];
    return NO;
  }
  if (startupResult == cot::SpawnRead::Failed) {
    // The child reported chdir/execve failure and is exiting: the lifecycle
    // retires the transport and reaps it; the caller gets the precise reason.
    [self terminate];
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:6
      userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Could not start %s: %s failed: %s",
        plan.executable().c_str(), failure.stage == cot::SpawnStageChdir ? "chdir" : "execve", strerror(failure.error)]}];
    return NO;
  }
  _running = YES;
  return YES;
#endif
}

// One reader (patch B): the lifecycle's READ source is the only path that reads
// the master. EOF is a transport event; the reaper alone decides child exit.
- (void)terminate {
  if (_terminalQueue == NULL || _native == NULL) return;
  [self withTransportOwner:^{ (*_native)->life->terminate(); }];
  _running = NO;
}

// Compatibility: asks the owner to make progress now (read what is ready, reap
// once). It is not a second reader; it runs the same generation-checked path.
// It must be called from outside the terminal queue: from the owner itself it
// would be a re-entrant read inside a READ-source or parser callback, so it is
// refused (visibly, as a transport error) instead of reading or blocking.
- (void)poll {
#if !defined(_WIN32)
  if (_terminalQueue == NULL || _native == NULL) return;
  if (dispatch_get_specific(&COTTerminalOwnerKey) == self) {
    NSLog(@"CocoaTerminal: -poll called on the terminal queue; ignored.");
    [self recordTransportError:@"-poll was called on the terminal queue and was ignored."];
    return;
  }
  dispatch_sync(_terminalQueue, ^{
    cot::SessionLifecycle *life = (*_native)->life.get();
    life->readable(life->generation());
    life->reap(life->generation());
  });
#endif
}

- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows {
  if (_fixedGrid) return; // Policy refusal: neither parser nor PTY is resized.
  NSUInteger targetColumns = MIN(MAX(columns, 1), COTTerminalMaximumColumns);
  NSUInteger targetRows = MIN(MAX(rows, 1), COTTerminalMaximumRows);
  _columns = targetColumns;
  _rows = targetRows;

  if (!_running) {
    if (_grid == NULL) {
      return;
    }
    dispatch_sync(_terminalQueue, ^{
      if (_grid != NULL) {
        _grid->resize(targetColumns, targetRows);
        [self publishSnapshotAndNotify:YES];
      }
    });
    return;
  }

  @synchronized (self) {
    _pendingColumns = targetColumns;
    _pendingRows = targetRows;
    if (_resizeOperationScheduled) {
      return;
    }
    _resizeOperationScheduled = YES;
  }

  dispatch_async(_terminalQueue, ^{
    for (;;) {
      NSUInteger resizeColumns = 0;
      NSUInteger resizeRows = 0;
      @synchronized (self) {
        resizeColumns = _pendingColumns;
        resizeRows = _pendingRows;
      }
      if (_grid == NULL) {
        @synchronized (self) {
          _resizeOperationScheduled = NO;
        }
        return;
      }
      _grid->resize(resizeColumns, resizeRows);

#if !defined(_WIN32)
      if (_masterFd >= 0) {
        struct winsize size;
        size.ws_col = (unsigned short)resizeColumns;
        size.ws_row = (unsigned short)resizeRows;
        size.ws_xpixel = 0;
        size.ws_ypixel = 0;
        ioctl(_masterFd, TIOCSWINSZ, &size);
      }
#endif
      [self publishSnapshotAndNotify:YES];

      @synchronized (self) {
        if (_pendingColumns == resizeColumns && _pendingRows == resizeRows) {
          _resizeOperationScheduled = NO;
          return;
        }
      }
    };
  });
}

- (COTTerminalEnqueueResult)trySendInput:(NSData *)data {
  // Refuse Observe/oversized input before copying mutable NSData.
  if (!_allowsInput || [data length] > cot::TransportWriter::MaximumPendingBytes) {
    __block COTTerminalEnqueueResult earlyResult;
    [self withTransportOwner:^{
      // Core checks policy/state/capacity before touching the data pointer.
      earlyResult = [self enqueueOnOwner:data];
    }];
    return earlyResult;
  }
  NSData *owned = [data copy];
  __block COTTerminalEnqueueResult result;
  [self withTransportOwner:^{ result = [self enqueueOnOwner:owned]; }];
  [owned release];
  return result;
}
- (NSString *)transportError {
  __block NSString *value = nil;
  [self withTransportOwner:^{ value = [_transportError copy]; }];
  return [value autorelease];
}
- (void)sendInput:(NSData *)data {
  COTTerminalEnqueueResult result = [self trySendInput:data];
  if (result == COTTerminalEnqueueAccepted && [self viewportOffset] > 0) {
    [self performGridMutation:^{ _grid->scrollToBottom(); } notify:YES];
  }
}

- (BOOL)allowsInput { return _allowsInput; }
- (BOOL)allowsLocalCopy { return _allowsInput; }
- (BOOL)fixedGrid { return _fixedGrid; }

- (void)ingestOutputData:(NSData *)data {
  if (_allowsInput || [data length] == 0) return;
  NSData *owned = [data copy];
  [self performGridMutation:^{
    _grid->ingest((const char *)[owned bytes], [owned length]);
    [owned release];
  } notify:YES];
}

- (NSArray<NSString *> *)visibleLines {
  COTTerminalSnapshot *snapshot = [self currentSnapshot];
  std::vector<std::string> source = snapshot->lines;
  NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:source.size()];
  for (const std::string &line : source) {
    NSString *string = [[[NSString alloc] initWithBytes:line.data()
                                                 length:line.size()
                                               encoding:NSUTF8StringEncoding] autorelease];
    [lines addObject:string != nil ? string : @""];
  }
  return lines;
}

- (NSArray<NSArray<NSDictionary *> *> *)styledVisibleRows {
  COTTerminalSnapshot *snapshot = [self currentSnapshot];
  std::vector<std::vector<cot::TerminalCell>> source = snapshot->cells;
  NSMutableArray *rows = [NSMutableArray arrayWithCapacity:source.size()];
  for (const std::vector<cot::TerminalCell> &cells : source) {
    NSMutableArray *row = [NSMutableArray array];
    for (const cot::TerminalCell &cell : cells) {
      if (cell.continuation) {
        continue;
      }
      NSString *text = [[[NSString alloc] initWithBytes:cell.text.data()
                                                 length:cell.text.size()
                                               encoding:NSUTF8StringEncoding] autorelease];
      if (text == nil) {
        text = @" ";
      }
      NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
        text, @"text",
        [NSNumber numberWithInt:cell.width], @"width",
        COTDictionaryFromColor(cell.attributes.foreground), @"foreground",
        COTDictionaryFromColor(cell.attributes.background), @"background",
        [NSNumber numberWithBool:cell.attributes.bold], @"bold",
        [NSNumber numberWithBool:cell.attributes.dim], @"dim",
        [NSNumber numberWithBool:cell.attributes.italic], @"italic",
        [NSNumber numberWithBool:cell.attributes.underline], @"underline",
        [NSNumber numberWithBool:cell.attributes.inverse], @"inverse",
        nil];
      [row addObject:attributes];
    }
    [rows addObject:row];
  }
  return rows;
}

- (NSUInteger)scrollbackLineCount {
  return [self currentSnapshot]->scrollbackLineCount;
}

- (void)setScrollbackLineLimit:(NSUInteger)limit {
  [_configuration setScrollbackLineLimit:limit];
  if (_grid == NULL) {
    return;
  }
  // The grid is only touched on the terminal queue. That queue never waits on the main thread, so waiting here is safe.
  dispatch_sync(_terminalQueue, ^{
    if (_grid != NULL) {
      _grid->setScrollbackLimit(limit);
      [self publishSnapshotAndNotify:YES];
    }
  });
}

- (NSUInteger)viewportOffset {
  return [self currentSnapshot]->viewportOffset;
}

- (NSUInteger)maxViewportOffset {
  return [self currentSnapshot]->maxViewportOffset;
}

- (void)setViewportOffset:(NSUInteger)offset {
  [self performGridMutation:^{
    _grid->setViewportOffset(offset);
  } notify:YES];
}

- (void)adjustViewportOffset:(NSInteger)delta {
  [self performGridMutation:^{
    _grid->adjustViewportOffset((long)delta);
  } notify:YES];
}

- (void)scrollToBottom {
  [self performGridMutation:^{
    _grid->scrollToBottom();
  } notify:YES];
}

- (NSUInteger)cursorColumn {
  return [self currentSnapshot]->cursorColumn;
}

- (NSUInteger)cursorRow {
  return [self currentSnapshot]->cursorRow;
}

- (BOOL)isUsingAlternateScreen {
  return [self currentSnapshot]->usingAlternateScreen;
}

- (BOOL)hasUsedAlternateScreen {
  return [self currentSnapshot]->hasUsedAlternateScreen;
}

- (BOOL)hasColorSpans {
  return [self currentSnapshot]->hasColorSpans;
}

- (BOOL)hasUnicode {
  return [self currentSnapshot]->hasUnicode;
}

- (BOOL)isMouseReportingEnabled {
  return [self currentSnapshot]->mouseReportingEnabled;
}

- (BOOL)isMouseButtonMotionReportingEnabled {
  return [self currentSnapshot]->mouseButtonMotionReportingEnabled;
}

- (BOOL)isMouseAnyMotionReportingEnabled {
  return [self currentSnapshot]->mouseAnyMotionReportingEnabled;
}

- (BOOL)isSGRMouseModeEnabled {
  return [self currentSnapshot]->sgrMouseModeEnabled;
}

- (BOOL)isAlternateScrollModeEnabled {
  return [self currentSnapshot]->alternateScrollModeEnabled;
}

- (BOOL)isCursorVisible {
  return [self currentSnapshot]->cursorVisible;
}

- (BOOL)isBracketedPasteEnabled {
  return [self currentSnapshot]->bracketedPasteEnabled;
}

- (BOOL)isFocusReportingEnabled {
  return [self currentSnapshot]->focusReportingEnabled;
}

- (NSString *)title {
  return [self currentSnapshot]->title ?: @"";
}

- (NSString *)lastClipboardWrite {
  return _lastClipboardWrite;
}

- (NSUInteger)clipboardWriteCount {
  return _clipboardWriteCount;
}

@synthesize configuration = _configuration;
@synthesize delegate = _delegate;
@synthesize running = _running;
@synthesize columns = _columns;
@synthesize rows = _rows;

@end

@implementation COTTerminalSession (Internal)

- (COTTerminalSnapshot *)currentSnapshot {
  [_snapshotLock lock];
  COTTerminalSnapshot *snapshot = [_snapshot retain];
  [_snapshotLock unlock];
  return [snapshot autorelease];
}

- (NSArray<NSNumber *> *)takeDirtyRows {
  COTTerminalSnapshot *snapshot = [self currentSnapshot];
  if (snapshot == nil) {
    return [NSArray array];
  }
  NSMutableArray *rows = [NSMutableArray array];
  for (std::size_t row = 0; row < snapshot->dirtyRows.size(); ++row) {
    if (snapshot->dirtyRows[row]) {
      [rows addObject:[NSNumber numberWithUnsignedLong:row]];
    }
  }
  return rows;
}

@end
