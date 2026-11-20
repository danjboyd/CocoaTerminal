// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalSession.h>

#import "COTTerminalSessionInternal.h"

#include "COTTerminalGrid.h"

#import <dispatch/dispatch.h>

#if defined(_WIN32)
#include "COTConPTY.h"
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#if defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__)
#include <pty.h>
#endif

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

#if defined(_WIN32) && defined(GNUSTEP)
// GNUstep base for Windows (MSYS2's, at least) is built without libdispatch, so its run loop never drains the main
// dispatch queue, and nothing this session sends the main thread (screen updates, title, exit) would arrive. On Linux
// base watches libdispatch's main-queue descriptor; here we watch its event handle the same way.
extern "C" void *_dispatch_get_main_queue_handle_4CF(void);
extern "C" void _dispatch_main_queue_callback_4CF(void *message);

@interface COTMainQueueWatcher : NSObject <RunLoopEvents>
+ (void)install;
@end

@implementation COTMainQueueWatcher

- (void)receivedEvent:(void *)data type:(RunLoopEventType)type extra:(void *)extra forMode:(NSString *)mode {
  (void)data;
  (void)type;
  (void)extra;
  (void)mode;
  _dispatch_main_queue_callback_4CF(NULL);
}

+ (void)install {
  static BOOL installed = NO;
  if (installed) {
    return;
  }
  if (![NSThread isMainThread]) {
    [self performSelectorOnMainThread:@selector(install) withObject:nil waitUntilDone:NO];
    return;
  }
  installed = YES;
  void *handle = _dispatch_get_main_queue_handle_4CF();
  if (handle == NULL) {
    return;
  }
  COTMainQueueWatcher *watcher = [[COTMainQueueWatcher alloc] init];  // lives as long as the process
  NSRunLoop *loop = [NSRunLoop mainRunLoop];
  NSArray *modes = [NSArray arrayWithObjects:NSDefaultRunLoopMode, @"NSEventTrackingRunLoopMode",
                                             @"NSModalPanelRunLoopMode", nil];
  for (NSString *mode in modes) {
    [loop addEvent:handle type:ET_HANDLE watcher:watcher forMode:mode];
  }
  _dispatch_main_queue_callback_4CF(NULL);  // anything queued before now
}

@end
#endif

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
#if defined(_WIN32)
  cot::ConPTYProcess *_conpty;
  int _windowsExitCode;
#else
  int _masterFd;
  pid_t _childPid;
#endif
  BOOL _running;
  BOOL _allowsInput;
  BOOL _fixedGrid;
  NSUInteger _columns;
  NSUInteger _rows;
  NSFileHandle *_readHandle;
  BOOL _exitDelivered;
  BOOL _outputPublishPending;  // terminal queue only
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

#if defined(_WIN32)
// Output the ConPTY reader has read and the terminal queue hasn't parsed yet.
struct COTOutputBatch {
  std::mutex mutex;
  std::string pending;
  bool drainScheduled = false;
};
#endif

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

// On the terminal queue, after output was parsed: one snapshot for all the output queued behind it, not one per read.
// ConPTY delivers output a line at a time (about 90 bytes), and copying the whole screen for each was half the time
// spent on heavy output. The publish goes behind whatever is queued now, so a burst of reads ends in one snapshot.
- (void)publishAfterQueuedOutput {
  if (_outputPublishPending) {
    return;
  }
  _outputPublishPending = YES;
  COTSessionHandle *handle = [_handle retain];
  dispatch_async(_terminalQueue, ^{
    @autoreleasepool {
      COTTerminalSession *session = handle->session;  // nil once -dealloc has begun; then the grid may be gone
      if (session != nil) {
        [session flushPendingOutputPublish];
      }
      [handle release];
    }
  });
}

// On the terminal queue: the snapshot output is waiting for, now. The exit paths call this so the host sees the final
// screen before the exit.
- (void)flushPendingOutputPublish {
  if (_outputPublishPending && _grid != NULL) {
    _outputPublishPending = NO;
    [self publishSnapshotAndNotify:YES];
  }
}

- (void)performGridMutation:(dispatch_block_t)block notify:(BOOL)notify {
  dispatch_async(_terminalQueue, ^{
    // GNUstep's libdispatch doesn't drain an autorelease pool around each block, as Apple's does, so without this
    // every update's snapshot (a copy of the whole screen) stayed alive: gigabytes under heavy output.
    @autoreleasepool {
      if (_grid == NULL) {
        return;
      }
      block();
      [self publishSnapshotAndNotify:notify];
    }
  });
}

- (instancetype)initWithConfiguration:(COTTerminalConfiguration *)configuration {
  self = [super init];
  if (self) {
#if defined(_WIN32) && defined(GNUSTEP)
    [COTMainQueueWatcher install];
#endif
#if !defined(_WIN32)
    _masterFd = -1;  // before any early return: -dealloc closes it
    _childPid = -1;
#endif
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
    _grid->setClipboardQueryCallback([unsafeSelf](int mask) {
      [unsafeSelf answerClipboardQueryWithMask:mask];
    });
#if defined(_WIN32)
    _conpty = NULL;
    _windowsExitCode = 0;
#else
    _masterFd = -1;
    _childPid = -1;
#endif
    _running = NO;
    _terminalQueue = dispatch_queue_create("org.cocoaterminal.session", DISPATCH_QUEUE_SERIAL);
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

- (void)writeReplyBytes:(const char *)bytes length:(std::size_t)length {
  if (!_allowsInput) return;
#if defined(_WIN32)
  if (_conpty != NULL && length > 0) {
    _conpty->write(bytes, length);
  }
#else
  if (_masterFd >= 0 && length > 0) {
    ssize_t total = 0;
    while (total < (ssize_t)length) {
      ssize_t written = write(_masterFd, bytes + total, length - total);
      if (written <= 0) {
        break;
      }
      total += written;
    }
  }
#endif
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
  NSString *previous = _lastClipboardWrite;
  _lastClipboardWrite = [text copy];
  [previous release];
  _clipboardWriteCount += 1;
  // The pasteboard on the main thread, as AppKit wants: here on the terminal queue, GNUstep's Win32 pasteboard blocked
  // the queue, and the screen stopped updating.
  NSString *ownedText = [text copy];
  [self deliverOnMain:^(COTTerminalSession *session) {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    @try {
      [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
      [pasteboard setString:ownedText forType:NSStringPboardType];
    } @catch (NSException *exception) {
      // Pasteboard server may be unavailable on headless GNUstep; the write
      // is still observable via lastClipboardWrite.
      (void)exception;
    }
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:ownedText forKey:@"text"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"COTTerminalSessionClipboardDidWriteNotification"
                                                        object:session
                                                      userInfo:userInfo];
  }];
  [ownedText release];
}

// On the terminal queue, inside an OSC 52 query: read the pasteboard on the main thread, as AppKit wants (GNUstep's
// Win32 pasteboard blocked the terminal queue when read from it), then answer back on the terminal queue. The answer
// follows whatever output arrived meanwhile, as any terminal's reply may.
- (void)answerClipboardQueryWithMask:(int)mask {
  if (!_allowsInput) {  // Observe: no pasteboard reads, and no reply
    return;
  }
  COTSessionHandle *handle = [_handle retain];
  dispatch_queue_t terminalQueue = _terminalQueue;
  dispatch_async(dispatch_get_main_queue(), ^{
    COTTerminalSession *session = handle->session;
    if (session == nil) {
      [handle release];
      return;
    }
    std::string value = [session readClipboardForRemote];
    dispatch_async(terminalQueue, ^{
      COTTerminalSession *current = handle->session;
      if (current != nil) {
        [current answerClipboardQueryOnTerminalQueue:mask value:value];
      }
      [handle release];
    });
  });
}

- (void)answerClipboardQueryOnTerminalQueue:(int)mask value:(const std::string &)value {
  if (_grid != NULL) {
    _grid->answerClipboardQuery(mask, value);
  }
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
  if (_handle != nil) {  // nil after a refused configuration
    _handle->session = nil;  // first: anything queued for the main thread now finds nothing
  }
  [self terminate];
  if (_terminalQueue != NULL) dispatch_sync(_terminalQueue, ^{
    delete _grid;
    _grid = NULL;
#if defined(_WIN32)
    delete _conpty;
    _conpty = NULL;
#endif
  });
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
  std::vector<std::string> argv;
  for (NSString *argument in _configuration.shellCommand) {
    argv.push_back([argument UTF8String] ?: "");
  }
  if (argv.empty() || argv[0].empty()) {
    argv.assign(1, "powershell.exe");
  }
  std::vector<std::pair<std::string, std::string>> environment;
  NSDictionary<NSString *, NSString *> *configured = _configuration.environment;
  for (NSString *key in configured) {
    NSString *value = [configured objectForKey:key];
    if ([key length] > 0 && value != nil) {
      environment.emplace_back([key UTF8String], [value UTF8String] ?: "");
    }
  }
  if ([_configuration.terminalType length] > 0) {
    environment.emplace_back("TERM", [[_configuration terminalType] UTF8String]);
  }
  environment.emplace_back("COLORTERM", "truecolor");
  std::string workingDirectory;
  if ([_configuration.workingDirectory length] > 0) {
    workingDirectory = [_configuration.workingDirectory UTF8String] ?: "";
  }

  // The reader thread's callbacks hold no reference to the session. -dealloc ends the process (joining that thread)
  // before it frees anything, and drains the terminal queue before the grid goes.
  void *rawSelf = self;
  COTSessionHandle *handle = _handle;
  dispatch_queue_t terminalQueue = _terminalQueue;
  cot::ConPTYProcess::Callbacks callbacks;
  // ConPTY hands over output about 90 bytes at a time, and parsing costs mostly per call (1 MB parses in 2.5 s in
  // 96-byte pieces, 0.2 s in 4 KB ones). So the reader appends to a buffer, and one block on the terminal queue takes
  // everything that has arrived by the time it runs: under load the pieces grow by themselves.
  auto batch = std::make_shared<COTOutputBatch>();
  callbacks.output = [rawSelf, terminalQueue, batch](const char *bytes, std::size_t length) {
    bool schedule = false;
    {
      std::lock_guard<std::mutex> lock(batch->mutex);
      batch->pending.append(bytes, length);
      schedule = !batch->drainScheduled;
      batch->drainScheduled = true;
    }
    if (!schedule) {
      return;
    }
    @autoreleasepool {
      std::shared_ptr<COTOutputBatch> owned = batch;
      dispatch_async(terminalQueue, ^{
        @autoreleasepool {  // see -performGridMutation:notify:
          std::string chunk;
          {
            std::lock_guard<std::mutex> lock(owned->mutex);
            chunk.swap(owned->pending);
            owned->drainScheduled = false;
          }
          NSData *data = [[NSData alloc] initWithBytesNoCopy:(void *)chunk.data() length:chunk.size() freeWhenDone:NO];
          [(COTTerminalSession *)rawSelf ingestOwnedData:data];
          [data release];
        }
      });
    }
  };
  callbacks.exited = [handle](std::uint32_t exitCode) {
    @autoreleasepool {
      dispatch_async(dispatch_get_main_queue(), ^{
        COTTerminalSession *session = handle->session;
        if (session != nil) {
          [session deliverChildExitWithStatus:(int)exitCode];
        }
      });
    }
  };

  if (_conpty != NULL) {
    dispatch_sync(_terminalQueue, ^{
      delete _conpty;
      _conpty = NULL;
    });
  }
  std::string message;
  std::unique_ptr<cot::ConPTYProcess> process = cot::ConPTYProcess::spawn(
    argv, environment, workingDirectory, (unsigned)_columns, (unsigned)_rows, std::move(callbacks), &message);
  if (!process) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:COTTerminalErrorDomain
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:message.c_str()] ?: @"ConPTY failed"}];
    }
    return NO;
  }
  cot::ConPTYProcess *started = process.release();
  dispatch_sync(_terminalQueue, ^{
    _conpty = started;
  });
  _running = YES;
  _exitDelivered = NO;
  _windowsExitCode = 0;
  return YES;
#else
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

  _masterFd = master;
  _childPid = pid;
  _running = YES;
  _exitDelivered = NO;
  fcntl(_masterFd, F_SETFL, fcntl(_masterFd, F_GETFL, 0) | O_NONBLOCK);
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
  NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
  if (data == nil || [data length] == 0) {
    [self deliverChildExit];
    return;
  }
  [self recordPerfReadWithByteCount:[data length]];
  NSData *ownedData = [data copy];
  dispatch_async(_terminalQueue, ^{
    @autoreleasepool {
      if (_grid != NULL) {
        [self recordPerfIngest];
        _grid->ingest((const char *)[ownedData bytes], (std::size_t)[ownedData length]);
        [self publishAfterQueuedOutput];
      }
      [ownedData release];
    }
  });
  if (_readHandle != nil) {
    [_readHandle readInBackgroundAndNotify];
  }
}

// On the terminal queue: output the reader thread read.
- (void)ingestOwnedData:(NSData *)data {
  if (_grid == NULL) {
    return;
  }
  [self recordPerfReadWithByteCount:[data length]];
  [self recordPerfIngest];
  _grid->ingest((const char *)[data bytes], (std::size_t)[data length]);
  [self publishAfterQueuedOutput];
}

#if defined(_WIN32)
// On the main thread, after the last of the shell's output was queued (the reader thread sends this once it's read it).
- (void)deliverChildExitWithStatus:(int)status {
  _windowsExitCode = status;
  // Behind the queued output, so the host sees the final screen before the exit.
  COTSessionHandle *handle = [_handle retain];
  dispatch_async(_terminalQueue, ^{
    @autoreleasepool {
      COTTerminalSession *queued = handle->session;
      if (queued != nil) {
        [queued flushPendingOutputPublish];  // the last output's snapshot goes first
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      COTTerminalSession *session = handle->session;
      if (session != nil) {
        [session deliverChildExit];
      }
      [handle release];
    });
  });
}
#endif

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
#if defined(_WIN32)
  status = _windowsExitCode;
  if (_conpty != NULL) {
    _conpty->terminate();  // the threads have finished; this joins them and closes the handles
  }
#else
  // The shell's last output before its exit: what's still in the pty, then everything queued for the grid. -poll found
  // the exit right after queuing that output, and the delegate heard of it before the screen showed it.
  if (_masterFd >= 0) {
    char buffer[8192];
    for (;;) {
      ssize_t count = read(_masterFd, buffer, sizeof(buffer));
      if (count <= 0) {
        break;
      }
      NSData *ownedData = [[NSData alloc] initWithBytes:buffer length:(NSUInteger)count];
      [self performGridMutation:^{
        _grid->ingest((const char *)[ownedData bytes], (std::size_t)[ownedData length]);
        [ownedData release];
      } notify:YES];
    }
  }
  dispatch_sync(_terminalQueue, ^{
    @autoreleasepool {
      [self flushPendingOutputPublish];
    }
  });
  if (_childPid > 0) {
    waitpid(_childPid, &status, 0);
    _childPid = -1;
  }
#endif
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
#if defined(_WIN32)
  if (_conpty != NULL) {
    _conpty->terminate();  // deleted in -dealloc or the next start, on the terminal queue
  }
#else
  if (_childPid > 0) {
    kill(_childPid, SIGHUP);
    int status = 0;
    waitpid(_childPid, &status, WNOHANG);
    _childPid = -1;
  }
  if (_masterFd >= 0) {
    close(_masterFd);
    _masterFd = -1;
  }
#endif
  _running = NO;
}

// On Windows a thread reads the console and delivers on its own, so there's nothing to poll.
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

#if defined(_WIN32)
      if (_conpty != NULL) {
        _conpty->resize((unsigned)resizeColumns, (unsigned)resizeRows);
      }
#else
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

- (void)sendInput:(NSData *)data {
  if (!_allowsInput) return;
#if defined(_WIN32)
  BOOL wrote = _conpty != NULL && _running && [data length] > 0 &&
               _conpty->write((const char *)[data bytes], (std::size_t)[data length]);
#else
  BOOL wrote = _masterFd >= 0 && [data length] > 0;
  if (wrote) {
    (void)write(_masterFd, [data bytes], [data length]);
  }
#endif
  if (wrote && [self viewportOffset] > 0) {
    [self performGridMutation:^{
      _grid->scrollToBottom();
    } notify:YES];
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
