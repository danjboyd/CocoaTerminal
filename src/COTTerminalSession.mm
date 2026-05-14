// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalSession.h>

#import "COTTerminalSessionInternal.h"

#include "COTTerminalGrid.h"

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
}
@end

@implementation COTTerminalSession

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
    _masterFd = -1;
    _childPid = -1;
    _running = NO;
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
  if ([_delegate respondsToSelector:@selector(terminalSession:didChangeTitle:)]) {
    [_delegate terminalSession:self didChangeTitle:value];
  }
  NSDictionary *userInfo = [NSDictionary dictionaryWithObject:value forKey:@"title"];
  [[NSNotificationCenter defaultCenter] postNotificationName:@"COTTerminalSessionTitleDidChangeNotification"
                                                      object:self
                                                    userInfo:userInfo];
}

- (void)deliverBell {
  if ([_delegate respondsToSelector:@selector(terminalSessionDidRequestBell:)]) {
    [_delegate terminalSessionDidRequestBell:self];
  }
}

- (instancetype)init {
  return [self initWithConfiguration:[COTTerminalConfiguration defaultConfiguration]];
}

- (void)dealloc {
  [self terminate];
  delete _grid;
  [_configuration release];
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
  _grid->ingest((const char *)[data bytes], (std::size_t)[data length]);
  if ([_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
    [_delegate terminalSessionDidUpdateScreen:self];
  }
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
      _grid->ingest(buffer, (std::size_t)count);
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
  if (changed && [_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
    [_delegate terminalSessionDidUpdateScreen:self];
  }
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
  _columns = MAX(columns, 1);
  _rows = MAX(rows, 1);
  _grid->resize(_columns, _rows);

#if !defined(_WIN32)
  if (_masterFd >= 0) {
    struct winsize size;
    size.ws_col = (unsigned short)_columns;
    size.ws_row = (unsigned short)_rows;
    size.ws_xpixel = 0;
    size.ws_ypixel = 0;
    ioctl(_masterFd, TIOCSWINSZ, &size);
  }
#endif
}

- (void)sendInput:(NSData *)data {
#if !defined(_WIN32)
  if (_masterFd >= 0 && [data length] > 0) {
    (void)write(_masterFd, [data bytes], [data length]);
    if (_grid->viewportOffset() > 0) {
      _grid->scrollToBottom();
      if ([_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
        [_delegate terminalSessionDidUpdateScreen:self];
      }
    }
  }
#else
  (void)data;
#endif
}

- (NSArray<NSString *> *)visibleLines {
  std::vector<std::string> source = _grid->viewportLines();
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
  std::vector<std::vector<cot::TerminalCell>> source = _grid->viewportCells();
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
  return _grid->scrollbackLineCount();
}

- (NSUInteger)viewportOffset {
  return _grid->viewportOffset();
}

- (NSUInteger)maxViewportOffset {
  return _grid->maxViewportOffset();
}

- (void)setViewportOffset:(NSUInteger)offset {
  _grid->setViewportOffset(offset);
  if ([_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
    [_delegate terminalSessionDidUpdateScreen:self];
  }
}

- (void)adjustViewportOffset:(NSInteger)delta {
  _grid->adjustViewportOffset((long)delta);
  if ([_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
    [_delegate terminalSessionDidUpdateScreen:self];
  }
}

- (void)scrollToBottom {
  _grid->scrollToBottom();
  if ([_delegate respondsToSelector:@selector(terminalSessionDidUpdateScreen:)]) {
    [_delegate terminalSessionDidUpdateScreen:self];
  }
}

- (NSUInteger)cursorColumn {
  return _grid->cursorColumn();
}

- (NSUInteger)cursorRow {
  return _grid->cursorRow();
}

- (BOOL)isUsingAlternateScreen {
  return _grid->usingAlternateScreen();
}

- (BOOL)hasUsedAlternateScreen {
  return _grid->hasUsedAlternateScreen();
}

- (BOOL)hasColorSpans {
  return _grid->hasColorSpans();
}

- (BOOL)hasUnicode {
  return _grid->hasUnicode();
}

- (BOOL)isMouseReportingEnabled {
  return _grid->mouseReportingEnabled();
}

- (BOOL)isMouseButtonMotionReportingEnabled {
  return _grid->mouseButtonMotionReportingEnabled();
}

- (BOOL)isMouseAnyMotionReportingEnabled {
  return _grid->mouseAnyMotionReportingEnabled();
}

- (BOOL)isSGRMouseModeEnabled {
  return _grid->sgrMouseModeEnabled();
}

- (BOOL)isAlternateScrollModeEnabled {
  return _grid->alternateScrollModeEnabled();
}

- (BOOL)isCursorVisible {
  return _grid->cursorVisible();
}

- (BOOL)isBracketedPasteEnabled {
  return _grid->bracketedPasteEnabled();
}

- (BOOL)isFocusReportingEnabled {
  return _grid->focusReportingEnabled();
}

- (NSString *)title {
  const std::string &t = _grid->title();
  if (t.empty()) {
    return @"";
  }
  NSString *value = [[[NSString alloc] initWithBytes:t.data() length:t.size() encoding:NSUTF8StringEncoding] autorelease];
  return value != nil ? value : @"";
}

@synthesize configuration = _configuration;
@synthesize delegate = _delegate;
@synthesize running = _running;
@synthesize columns = _columns;
@synthesize rows = _rows;

@end

@implementation COTTerminalSession (Internal)

- (const cot::TerminalGrid *)gridPointer {
  return _grid;
}

- (NSArray<NSNumber *> *)takeDirtyRows {
  if (_grid == NULL) {
    return [NSArray array];
  }
  std::vector<bool> rows;
  _grid->getAndClearDirtyRows(rows);
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:rows.size()];
  for (std::size_t i = 0; i < rows.size(); ++i) {
    if (rows[i]) {
      [result addObject:[NSNumber numberWithUnsignedInteger:(NSUInteger)i]];
    }
  }
  return result;
}

@end
