// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

// A session's main-thread callbacks after it's released, and key equivalents in an unfocused terminal view.
//
// 1. A screen update queued for the main thread, then the session released before the main queue runs: the delegate
//    hears nothing, and nothing touches freed memory (run under AddressSanitizer to see it). Before, the queued block
//    held a retain taken on the terminal queue; when that retain raced with -dealloc it revived a freed session.
// 2. With an argument and a display: a text field focused beside an interactive terminal keeps Ctrl+Shift+V and Ctrl+C;
//    the terminal takes them only when it's focused.

#import <CocoaTerminal/CocoaTerminal.h>
#import <AppKit/AppKit.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << message << "\n";
    std::exit(1);
  }
}

@interface COTUpdateCounter : NSObject <COTTerminalDelegate>
@property(nonatomic, assign) int updates;
@end
@implementation COTUpdateCounter
@synthesize updates;
- (void)terminalSessionDidUpdateScreen:(COTTerminalSession *)session { updates++; }
@end

static void drainMain(NSTimeInterval seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}

int main(int argc, char **argv) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  // Control: an update reaches a live session's delegate.
  COTUpdateCounter *kept = [[COTUpdateCounter alloc] init];
  COTTerminalSession *live = [[COTTerminalSession alloc] initWithConfiguration:[COTTerminalConfiguration defaultConfiguration]];
  [live setDelegate:kept];
  [live resizeToColumns:40 rows:10];  // not started: the grid resizes on the terminal queue and queues an update
  drainMain(0.3);
  expect([kept updates] >= 1, "a live session's update should reach its delegate");
  [live release];

  // Released before the main queue ran: the queued update finds no session.
  COTUpdateCounter *counter = [[COTUpdateCounter alloc] init];
  COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:[COTTerminalConfiguration defaultConfiguration]];
  [session setDelegate:counter];
  [session resizeToColumns:41 rows:11];
  [session release];
  drainMain(0.3);
  expect([counter updates] == 0, "a released session's queued update still reached its delegate");
  [counter release];
  [kept release];

  if (argc > 1) {
    [NSApplication sharedApplication];
    COTTerminalView *terminal = [[COTTerminalView alloc] initWithFrame:NSMakeRect(0, 0, 400, 120)];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(400, 0, 200, 24)];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 200) styleMask:NSTitledWindowMask
                                                     backing:NSBackingStoreBuffered defer:YES];
    [[window contentView] addSubview:terminal];
    [[window contentView] addSubview:field];
    NSEvent *paste = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSCommandKeyMask | NSShiftKeyMask timestamp:0
                                  windowNumber:0 context:nil characters:@"v" charactersIgnoringModifiers:@"v" isARepeat:NO keyCode:0];
    NSEvent *ctrlC = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:NSControlKeyMask timestamp:0
                                  windowNumber:0 context:nil characters:@"\003" charactersIgnoringModifiers:@"c" isARepeat:NO keyCode:0];
    [window makeFirstResponder:field];
    expect(![terminal performKeyEquivalent:paste], "an unfocused terminal took Ctrl+Shift+V");
    expect(![terminal performKeyEquivalent:ctrlC], "an unfocused terminal took Ctrl+C");
    [window makeFirstResponder:terminal];
    expect([terminal performKeyEquivalent:paste], "the focused terminal should take Ctrl+Shift+V");
    [terminal removeFromSuperview];
    [field removeFromSuperview];
    [window release];
    [field release];
    [terminal release];
  }

  [pool drain];
  std::cout << (argc > 1 ? "lifetime and focus checks pass\n" : "lifetime checks pass\n");
  return 0;
}
