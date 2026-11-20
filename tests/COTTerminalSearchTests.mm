// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Search and links in a running view: -findPrevious:/-findNext: find text in the scrollback, scroll it into view and
// select it; the find bar shows and hides; -linkAtRow:column: finds a URL on screen. Needs a display; skips without.
// Focusing the find field makes GNUstep start its pasteboard server (gpbs) if it isn't running. It inherits this
// test's output, so ctest waits for it to go idle (about a minute) unless gpbs was already running.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

static BOOL AnyLineHasPrefix(COTTerminalSession *session, NSString *prefix) {
  for (NSString *line in [session visibleLines]) {
    if ([line hasPrefix:prefix]) return YES;
  }
  return NO;
}

static void Spin(NSTimeInterval seconds) {
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if !defined(__APPLE__) && !defined(_WIN32)
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
#endif
  [NSApplication sharedApplication];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  [configuration setScrollbackLineLimit:1000];
  // 120 numbered lines with two marked ones far apart, a link, then a prompt-like last line.
  NSString *script =
      @"i=1; while [ $i -le 120 ]; do "
       "if [ $i = 10 ]; then echo \"line $i Needle-old\"; elif [ $i = 100 ]; then echo \"line $i needle-new\"; "
       "else echo \"line $i\"; fi; i=$((i+1)); done; "
       "echo 'docs at (https://example.org/a_(b)/c?q=1).'; printf 'DONE'; exec sleep 30";
#if defined(_WIN32)
  NSString *shell = @"C:\\msys64\\usr\\bin\\sh.exe";
#else
  NSString *shell = @"/bin/sh";
#endif
  if (getenv("COT_SEARCH_TEST_SHELL")) shell = [NSString stringWithUTF8String:getenv("COT_SEARCH_TEST_SHELL")];
  [configuration setShellCommand:[NSArray arrayWithObjects:shell, @"-c", script, nil]];
  NSRect frame = NSMakeRect(0, 0, 640, 240);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];
  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  COTTerminalSession *session = [view session];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
  while ([deadline timeIntervalSinceNow] > 0 && !AnyLineHasPrefix(session, @"DONE")) Spin(0.05);
  expect(AnyLineHasPrefix(session, @"DONE"), "the output arrives");
  Spin(0.3);
  NSUInteger rows = [session rows];
  expect([session scrollbackLineCount] > 100 - rows, "the marked lines are in the scrollback");

  // Upward from the end: the newest match first, case ignored by default.
  expect([view findPrevious:@"NEEDLE"], "finds needle-new");
  Spin(0.2);
  expect([[view selectedText] isEqualToString:@"needle"], "the match is selected");
  NSUInteger newOffset = [session viewportOffset];
  expect(newOffset > 0, "and scrolled into view from the scrollback");
  BOOL visible = NO;
  for (NSString *line in [session visibleLines]) {
    if ([line hasPrefix:@"line 100 needle-new"]) visible = YES;
  }
  expect(visible, "needle-new's line is on screen");

  expect([view findPrevious:@"NEEDLE"], "finds Needle-old");
  Spin(0.2);
  expect([[view selectedText] isEqualToString:@"Needle"], "the older match is selected, as it's written");
  expect([session viewportOffset] > newOffset, "scrolled further back");

  expect([view findNext:@"needle"], "down again");
  Spin(0.2);
  expect([[view selectedText] isEqualToString:@"needle"], "back to needle-new");

  // No waiting from here on: a find has scrolled and selected by the time it returns.
  [view setFindCaseSensitive:YES];
  expect([view findPrevious:@"Needle"], "case-sensitive: Needle-old is found");
  expect([[view selectedText] isEqualToString:@"Needle"], "and it's the match selected, not needle-new");
  expect([view findNext:@"needle"] && [[view selectedText] isEqualToString:@"needle"],
         "case-sensitive 'needle' is a new search: from the end down, it wraps to the top and finds needle-new");
  [view setFindCaseSensitive:NO];

  expect(![view findPrevious:@"no-such-text"], "no match");
  expect([[view selectedText] length] == 0, "and nothing selected");

  [view showFindBar];
  expect([view isFindBarVisible], "the find bar shows");
  Spin(0.1);
  [view hideFindBar];
  expect(![view isFindBarVisible], "and hides");
  Spin(0.1);

  // Links, on the live screen.
  [session scrollToBottom];
  Spin(0.3);
  NSArray *lines = [session visibleLines];
  NSUInteger linkRow = NSNotFound;
  for (NSUInteger i = 0; i < [lines count]; i++) {
    if ([[lines objectAtIndex:i] hasPrefix:@"docs at"]) linkRow = i;
  }
  expect(linkRow != NSNotFound, "the link's line is on screen");
  NSURL *link = [view linkAtRow:linkRow column:15];
  expect(link != nil && [[link absoluteString] isEqualToString:@"https://example.org/a_(b)/c?q=1"],
         "the URL under a cell, without the sentence's bracket and full stop");
  expect([view linkAtRow:linkRow column:2] == nil, "plain words aren't links");

  [session terminate];
  [window close];
  [view release];
  [pool release];
  std::cout << "COTTerminalSearchTests passed\n";
  return 0;
}
