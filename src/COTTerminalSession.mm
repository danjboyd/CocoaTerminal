// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalSession.h>

#import "COTTerminalSessionInternal.h"

#include "COTTerminalGrid.h"

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

@interface COTTerminalSession () {
  COTTerminalConfiguration *_configuration;
  cot::TerminalGrid *_grid;
  int _masterFd;
  pid_t _childPid;
  BOOL _running;
  NSUInteger _columns;
  NSUInteger _rows;
  NSFileHandle *_readHandle;
  BOOL _exitDelivered;
  NSString *_lastClipboardWrite;
  NSUInteger _clipboardWriteCount;
  dispatch_queue_t _terminalQueue;
  NSLock *_snapshotLock;
  COTTerminalSnapshot *_snapshot;
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

- (void)publishSnapshotAndNotify:(BOOL)notify {
  COTTerminalSnapshot *snapshot = [[self snapshotFromGrid] retain];
  [_snapshotLock lock];
  [_snapshot release];
  _snapshot = snapshot;
  [_snapshotLock unlock];
  if (!notify) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
      [_delegate terminalSessionDidUpdateScreen:self];
    }
  });
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
    _configuration = [configuration copy];
    _columns = 80;
    _rows = 24;
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
    _snapshotLock = [[NSLock alloc] init];
    [self publishSnapshotAndNotify:NO];
  }
  return self;
}

- (void)writeReplyBytes:(const char *)bytes length:(std::size_t)length {
#if !defined(_WIN32)
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
  NSString *ownedValue = [value copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([_delegate respondsToSelector:@selector(terminalSession:didChangeTitle:)]) {
      [_delegate terminalSession:self didChangeTitle:ownedValue];
    }
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:ownedValue forKey:@"title"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"COTTerminalSessionTitleDidChangeNotification"
                                                        object:self
                                                      userInfo:userInfo];
    [ownedValue release];
  });
}

- (void)deliverBell {
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([_delegate respondsToSelector:@selector(terminalSessionDidRequestBell:)]) {
      [_delegate terminalSessionDidRequestBell:self];
    }
  });
}

- (void)deliverClipboardWrite:(const std::string &)data {
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
  [self terminate];
  dispatch_sync(_terminalQueue, ^{
    delete _grid;
    _grid = NULL;
  });
  [_configuration release];
  [_snapshotLock release];
  [_snapshot release];
  [_lastClipboardWrite release];
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
  NSData *ownedData = [data copy];
  [self performGridMutation:^{
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
  if (_masterFd >= 0) {
    close(_masterFd);
    _masterFd = -1;
  }
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
      NSData *ownedData = [[NSData alloc] initWithBytes:buffer length:(NSUInteger)count];
      [self performGridMutation:^{
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
  NSUInteger targetColumns = MIN(MAX(columns, 1), COTTerminalMaximumColumns);
  NSUInteger targetRows = MIN(MAX(rows, 1), COTTerminalMaximumRows);

  if (_running) {
    // Runtime libvterm resizes can stall the emulation queue on GNUstep/Linux.
    // Keep the running grid stable so resize storms cannot block input echo.
    _columns = targetColumns;
    _rows = targetRows;
    return;
  }

  _columns = targetColumns;
  _rows = targetRows;
  if (_grid == NULL) {
    return;
  }
  dispatch_sync(_terminalQueue, ^{
    if (_grid != NULL) {
      _grid->resize(targetColumns, targetRows);
      [self publishSnapshotAndNotify:YES];
    }
  });
}

- (void)sendInput:(NSData *)data {
#if !defined(_WIN32)
  if (_masterFd >= 0 && [data length] > 0) {
    (void)write(_masterFd, [data bytes], [data length]);
    if ([self viewportOffset] > 0) {
      [self performGridMutation:^{
        _grid->scrollToBottom();
      } notify:YES];
    }
  }
#else
  (void)data;
#endif
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
  return [NSArray array];
}

@end
