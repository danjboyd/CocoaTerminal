// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
#import <CocoaTerminal/CocoaTerminal.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <cstdlib>
#include <iostream>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <pty.h>
#include <sys/ioctl.h>

@interface COTTerminalSession (ObserverTests)
- (void)writeReplyBytes:(const char *)bytes length:(std::size_t)length;
- (void)deliverClipboardWrite:(const std::string &)data;
- (std::string)readClipboardForRemote;
@end
@interface COTTerminalView (ObserverTests)
- (void)updateTerminalSizeFromBounds;
- (void)sendMouseReportForEvent:(NSEvent *)event button:(int)button pressed:(BOOL)pressed;
@end
static unsigned pasteboardAccesses;
@interface COTPasteboardSpy : NSObject
+ (id)spyGeneralPasteboard;
@end
@implementation COTPasteboardSpy
+ (id)spyGeneralPasteboard { ++pasteboardAccesses; return nil; }
@end
static void expect(BOOL value, const char *message) {
  if (!value) { std::cerr << message << "\n"; std::exit(1); }
}
static void putFD(COTTerminalSession *session, int fd) {
  Ivar ivar = class_getInstanceVariable([COTTerminalSession class], "_masterFd");
  expect(ivar != NULL, "test transport injection unavailable");
  *(int *)((char *)session + ivar_getOffset(ivar)) = fd;
}
static void drainParser(COTTerminalSession *session) {
  Ivar ivar = class_getInstanceVariable([COTTerminalSession class], "_terminalQueue");
  dispatch_queue_t queue = *(dispatch_queue_t *)((char *)session + ivar_getOffset(ivar));
  dispatch_sync(queue, ^{});
}
int main(int argc, char **argv) {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  BOOL gui = argc > 1;
  if (gui) [NSApplication sharedApplication];
  Method real = class_getClassMethod([NSPasteboard class], @selector(generalPasteboard));
  Method spy = class_getClassMethod([COTPasteboardSpy class], @selector(spyGeneralPasteboard));
  method_exchangeImplementations(real, spy); // Never read/write the real clipboard.
  COTTerminalConfiguration *defaults = [COTTerminalConfiguration defaultConfiguration];
  expect(defaults.inputPolicy == COTTerminalInputPolicyInteractive && defaults.sizingPolicy == COTTerminalSizingPolicyFollowView && defaults.initialColumns == 80 && defaults.initialRows == 24, "compatibility defaults changed");
  COTTerminalConfiguration *config = [defaults copy];
  config.inputPolicy = COTTerminalInputPolicyObserve;
  config.sizingPolicy = COTTerminalSizingPolicyFixedGrid;
  config.initialColumns = 37; config.initialRows = 11;
  COTTerminalConfiguration *copy = [config copy];
  expect(copy.inputPolicy == config.inputPolicy && copy.sizingPolicy == config.sizingPolicy && copy.initialColumns == 37 && copy.initialRows == 11, "policy copy changed");
  COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:copy];
  expect(session != nil && !session.allowsInput && !session.allowsLocalCopy && session.fixedGrid, "observer construction failed");
  copy.inputPolicy = COTTerminalInputPolicyInteractive;
  session.configuration.inputPolicy = COTTerminalInputPolicyInteractive;
  session.configuration.sizingPolicy = COTTerminalSizingPolicyFollowView;
  expect(!session.allowsInput && session.fixedGrid, "configuration mutation promoted observer");
  int master = -1, slave = -1;
  struct winsize size = {11,37,0,0};
  expect(openpty(&master, &slave, NULL, NULL, &size) == 0, "disposable PTY allocation failed");
  fcntl(slave, F_SETFL, O_NONBLOCK);
  struct termios term; tcgetattr(slave, &term); cfmakeraw(&term); tcsetattr(slave, TCSANOW, &term);
  putFD(session, master);
  [session sendInput:[@"forbidden" dataUsingEncoding:NSUTF8StringEncoding]];
  [session writeReplyBytes:"forbidden-reply" length:15];
  [session deliverClipboardWrite:std::string("forbidden")];
  expect([session readClipboardForRemote].empty(), "observer clipboard read returned content");
  NSString *queries = @"visible\033[5n\033[6n\033[c\033[18t\033]52;c;?\007\033]52;c;Zm9yYmlkZGVu\007\033[8;40;120t\033[?1000h\033[?1004h\033[?2004h";
  [session ingestOutputData:[queries dataUsingEncoding:NSUTF8StringEncoding]];
  drainParser(session);
  expect([[session.visibleLines componentsJoinedByString:@"\n"] rangeOfString:@"visible"].location != NSNotFound, "observer failed to render output");
  [session resizeToColumns:119 rows:43]; [session resizeToColumns:0 rows:NSUIntegerMax];
  drainParser(session);
  ioctl(master, TIOCGWINSZ, &size);
  expect(session.columns == 37 && session.rows == 11 && size.ws_col == 37 && size.ws_row == 11, "fixed grid/PTY changed");
  expect([session clipboardWriteCount] == 0 && [session lastClipboardWrite] == nil, "output published clipboard content");
  char bytes[64]; expect(read(slave, bytes, sizeof(bytes)) < 0, "observer wrote transport bytes");
  close(slave); [session release]; [copy release];
  for (int invalid = 0; invalid < 6; ++invalid) {
    COTTerminalConfiguration *bad = [config copy];
    if (invalid == 0) bad.inputPolicy = (COTTerminalInputPolicy)99;
    if (invalid == 1) bad.sizingPolicy = (COTTerminalSizingPolicy)-1;
    if (invalid == 2) bad.initialColumns = 0;
    if (invalid == 3) bad.initialRows = 1001;
    if (invalid == 4) bad.initialColumns = NSUIntegerMax;
    if (invalid == 5) { [bad release]; bad = nil; }
    COTTerminalSession *rejected = [[COTTerminalSession alloc] initWithConfiguration:bad];
    expect(rejected == nil, "invalid configuration did not fail closed"); [bad release];
  }
  if (gui) {
    COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:NSMakeRect(0,0,800,120) configuration:config];
    expect(view != nil, "observer view failed");
    int viewMaster = -1, viewSlave = -1;
    struct winsize viewSize = {11,37,0,0};
    expect(openpty(&viewMaster, &viewSlave, NULL, NULL, &viewSize) == 0, "view PTY allocation failed");
    fcntl(viewSlave, F_SETFL, O_NONBLOCK);
    tcgetattr(viewSlave, &term); cfmakeraw(&term); tcsetattr(viewSlave, TCSANOW, &term);
    putFD(view.session, viewMaster);
    [view.session ingestOutputData:[queries dataUsingEncoding:NSUTF8StringEncoding]];
    drainParser(view.session);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,200) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:YES];
    [[window contentView] addSubview:view];
    [view updateTerminalSizeFromBounds];
    [view selectAll]; [view copySelection]; [view pasteFromClipboard];
    [view performSelector:@selector(copy:) withObject:nil]; [view performSelector:@selector(paste:) withObject:nil];
    [view becomeFirstResponder]; [view resignFirstResponder];
    NSEvent *key = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:0];
    [view keyDown:key]; [view performKeyEquivalent:key];
    NSEvent *paste = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSCommandKeyMask|NSShiftKeyMask timestamp:0 windowNumber:0 context:nil characters:@"v" charactersIgnoringModifiers:@"v" isARepeat:NO keyCode:0];
    [view keyDown:paste]; [view performKeyEquivalent:paste];
    [view sendMouseReportForEvent:key button:0 pressed:YES];
    [view setFrameSize:NSMakeSize(107,901)]; [view updateTerminalSizeFromBounds];
    [view setBounds:NSMakeRect(0,0,-1,-70)]; [view updateTerminalSizeFromBounds];
    [view zoomIn]; [view zoomOut]; [view resetZoom];
    expect(view.session.columns == 37 && view.session.rows == 11 && !view.session.allowsInput, "viewport/zoom changed observer grid or policy");
    drainParser(view.session);
    ioctl(viewMaster, TIOCGWINSZ, &viewSize);
    expect(viewSize.ws_col == 37 && viewSize.ws_row == 11, "view resized PTY");
    expect(read(viewSlave, bytes, sizeof(bytes)) < 0, "view bypass wrote input");
    close(viewSlave);
    [view removeFromSuperview]; [window release];
    [view release];
  }
  expect(pasteboardAccesses == 0, "observer accessed pasteboard before policy denial");
  method_exchangeImplementations(real, spy);
  [config release];
  std::cout << (gui ? "observer GUI and transport checks pass\n" : "observer transport checks pass\n");
  [pool drain]; return 0;
}
