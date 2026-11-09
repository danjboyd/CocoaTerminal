// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalSession.h>

#import "COTTerminalSessionInternal.h"

#include "COTTerminalGrid.h"
#include "COTTransportWriter.h"

#import <dispatch/dispatch.h>

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

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
  COTWriterTarget *_writerTarget;
  NSString *_transportError;
  int _masterFd;
  pid_t _childPid;
  BOOL _running;
  BOOL _allowsInput;
  BOOL _fixedGrid;
  NSUInteger _columns;
  NSUInteger _rows;
  NSFileHandle *_readHandle;
  BOOL _exitDelivered;
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
    COTTerminalSession *writerSelf = self;
    _writer = new cot::TransportWriter({
      [](int fd, const char *bytes, std::size_t length) -> cot::WriteResult {
        ssize_t count = write(fd, bytes, length);
        return {count, count < 0 ? errno : 0};
      },
      [writerSelf](int, std::uint64_t) { [writerSelf setWritableEnabled:YES]; },
      [writerSelf]() { [writerSelf setWritableEnabled:NO]; },
      [writerSelf](int fd) { [writerSelf retireWriterDescriptor:fd]; }
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
  if (!_writeSource || enabled == _writeSourceResumed) return;
  if (enabled) dispatch_resume(_writeSource); else dispatch_suspend(_writeSource);
  _writeSourceResumed = enabled;
}
- (void)retireWriterDescriptor:(int)fd {
  _masterFd = -1; // Borrowed alias only. No other method closes the descriptor.
  if (_writeSource) {
    dispatch_source_t source = _writeSource;
    _writeSource = NULL;
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_source_cancel(source);
    if (!_writeSourceResumed) dispatch_resume(source);
    _writeSourceResumed = NO;
#if !OS_OBJECT_USE_OBJC
    dispatch_release(source);
#endif
  } else close(fd);
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
- (BOOL)adoptTransportDescriptor:(int)descriptor {
  __block BOOL adopted = NO;
  [self withTransportOwner:^{
    if (!_writer->open(descriptor, _allowsInput)) return;
    _masterFd = descriptor;
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
      _writer->close();
      [self recordTransportError:@"Terminal nonblocking transport setup failed."];
      return;
    }
    const std::uint64_t generation = _writer->generation();
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, descriptor, 0, _terminalQueue);
    _writeSourceResumed = NO;
    if (!_writeSource) {
      _writer->close();
      [self recordTransportError:@"Terminal writable-readiness setup failed."];
      return;
    }
    COTWriterTarget *target = _writerTarget;
    dispatch_source_set_event_handler(_writeSource, ^{ [target.session writerWritable:generation]; });
    [self recordTransportError:nil];
    adopted = YES;
  }];
  return adopted;
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
  [self terminate];
  if (_terminalQueue != NULL) [self withTransportOwner:^{
    _writerTarget.session = nil;
    delete _writer; _writer = NULL;
    delete _grid;
    _grid = NULL;
  }];
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
  if (_masterFd >= 0) {
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:3
      userInfo:@{NSLocalizedDescriptionKey:@"Previous transport cleanup is required before restart."}];
    return NO;
  }
  struct winsize size;
  size.ws_col = (unsigned short)_columns;
  size.ws_row = (unsigned short)_rows;
  size.ws_xpixel = 0;
  size.ws_ypixel = 0;

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &size);
  if (pid < 0) {
    if (error != NULL) {
      NSString *message = [NSString stringWithFormat:@"forkpty failed: %s", strerror(errno)];
      *error = [NSError errorWithDomain:COTTerminalErrorDomain
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
  }

  if (pid == 0) {
    NSDictionary<NSString *, NSString *> *environment = _configuration.environment;
    for (NSString *key in environment) {
      NSString *value = [environment objectForKey:key];
      if ([key length] > 0 && value != nil) {
        setenv([key UTF8String], [value UTF8String], 1);
      }
    }
    if ([_configuration.terminalType length] > 0) {
      setenv("TERM", [[_configuration terminalType] UTF8String], 1);
    }
    setenv("COLORTERM", "truecolor", 1);

    if ([_configuration.workingDirectory length] > 0 &&
        chdir([_configuration.workingDirectory fileSystemRepresentation]) != 0) {
      _exit(126);
    }

    NSArray<NSString *> *command = _configuration.shellCommand;
    NSString *launchPath = [command count] > 0 ? [command objectAtIndex:0] : @"/bin/sh";
    NSUInteger argc = [command count];
    char **argv = static_cast<char **>(calloc(argc + 1, sizeof(char *)));
    for (NSUInteger index = 0; index < argc; ++index) {
      argv[index] = strdup([[command objectAtIndex:index] fileSystemRepresentation]);
    }
    argv[argc] = NULL;
    execvp([launchPath fileSystemRepresentation], argv);
    _exit(127);
  }

  _childPid = pid;
  if (![self adoptTransportDescriptor:master]) {
    [self terminate];
    if (error) *error = [NSError errorWithDomain:COTTerminalErrorDomain code:4
      userInfo:@{NSLocalizedDescriptionKey:@"Terminal writable-readiness setup failed."}];
    return NO;
  }
  _running = YES;
  _exitDelivered = NO;
  _readHandle = [[NSFileHandle alloc] initWithFileDescriptor:_masterFd closeOnDealloc:NO];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleReadCompletion:)
                                               name:NSFileHandleReadCompletionNotification
                                             object:_readHandle];
  [_readHandle readInBackgroundAndNotify];
  return YES;
#endif
}

- (void)handleReadCompletion:(NSNotification *)notification {
  if ([notification object] != _readHandle) return; // Ignore a retired reader.
  NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
  if (data == nil || [data length] == 0) {
    [self deliverChildExit];
    return;
  }
  [self recordPerfReadWithByteCount:[data length]];
  NSData *ownedData = [data copy];
  [self performGridMutation:^{
    [self recordPerfIngest];
    _grid->ingest((const char *)[ownedData bytes], (std::size_t)[ownedData length]);
    [ownedData release];
  } notify:YES];
  if (_readHandle != nil) {
    [_readHandle readInBackgroundAndNotify];
  }
}

- (void)deliverChildExit {
  if (_exitDelivered) {
    return;
  }
  _exitDelivered = YES;
  if (_readHandle != nil) {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:_readHandle];
  }
  int status = 0;
  if (_childPid > 0) {
    waitpid(_childPid, &status, 0);
    _childPid = -1;
  }
  _running = NO;
  if ([_delegate respondsToSelector:@selector(terminalSession:didExitWithStatus:)]) {
    [_delegate terminalSession:self didExitWithStatus:status];
  }
}

- (void)terminate {
  if (_readHandle != nil) {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:_readHandle];
    [_readHandle release];
    _readHandle = nil;
  }
  if (_childPid > 0) {
    kill(_childPid, SIGHUP);
    int status = 0;
    waitpid(_childPid, &status, WNOHANG);
    _childPid = -1;
  }
  if (_terminalQueue != NULL) [self withTransportOwner:^{
    if (_writer) _writer->close();
  }];
  _running = NO;
}

- (void)poll {
#if !defined(_WIN32)
  if (_masterFd < 0) {
    return;
  }
  char buffer[8192];
  bool changed = false;
  for (;;) {
    ssize_t count = read(_masterFd, buffer, sizeof(buffer));
    if (count > 0) {
      [self recordPerfReadWithByteCount:(NSUInteger)count];
      NSData *ownedData = [[NSData alloc] initWithBytes:buffer length:(NSUInteger)count];
      [self performGridMutation:^{
        [self recordPerfIngest];
        _grid->ingest((const char *)[ownedData bytes], (std::size_t)[ownedData length]);
        [ownedData release];
      } notify:YES];
      changed = true;
      continue;
    }
    if (count == 0) {
      [self deliverChildExit];
      break;
    }
    if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
      [self deliverChildExit];
    }
    break;
  }
  (void)changed;
  if (_childPid > 0) {
    int status = 0;
    pid_t result = waitpid(_childPid, &status, WNOHANG);
    if (result == _childPid) {
      [self deliverChildExit];
    }
  }
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
