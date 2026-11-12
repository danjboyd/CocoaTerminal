// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

// Changing a running terminal's look and scrollback: -[COTTerminalView applyTheme:], -[COTTerminalSession
// setScrollbackLineLimit:] and the standard 256-colour range. With an argument (a display), it also runs a shell in a
// view and checks applyTheme: re-measures the cells and the program gets SIGWINCH with the new size.

#import <CocoaTerminal/CocoaTerminal.h>
#import <AppKit/AppKit.h>

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <unistd.h>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << message << "\n";
    std::exit(1);
  }
}

static BOOL rgb(NSColor *color, int red, int green, int blue) {
  NSColor *c = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  return c != nil && (int)lround([c redComponent] * 255) == red && (int)lround([c greenComponent] * 255) == green &&
         (int)lround([c blueComponent] * 255) == blue;
}

static void spin(NSTimeInterval seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) {
    NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]
                                           inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event != nil) [NSApp sendEvent:event];
  }
}

// The last "rows cols" line the shell wrote on SIGWINCH, or nil.
static NSString *lastSize(NSString *path) {
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  NSArray *lines = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"];
  NSString *last = [lines lastObject];
  return [last length] ? last : nil;
}

int main(int argc, char **argv) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  // The standard 256-colour range: a 16-colour palette doesn't take it away.
  expect([COTTerminalTheme xtermColorAtIndex:15] == nil, "index 15 belongs to the theme's palette");
  expect([COTTerminalTheme xtermColorAtIndex:256] == nil, "there is no index 256");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:16], 0, 0, 0), "16 is the cube's black");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:21], 0, 0, 255), "21 is the cube's blue");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:196], 255, 0, 0), "196 is the cube's red");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:110], 135, 175, 215), "110 is 2,3,4 in the cube");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:231], 255, 255, 255), "231 is the cube's white");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:232], 8, 8, 8), "232 is the first grey");
  expect(rgb([COTTerminalTheme xtermColorAtIndex:255], 238, 238, 238), "255 is the last grey");

  // Scrollback on a session, without starting it: the configuration follows, and nothing waits forever.
  COTTerminalConfiguration *configuration = [[COTTerminalConfiguration defaultConfiguration] copy];
  COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:configuration];
  [session setScrollbackLineLimit:5];
  expect([[session configuration] scrollbackLineLimit] == 5, "the session's configuration should take the new limit");
  expect([session scrollbackLineCount] == 0, "nothing was written, so nothing is held");
  [session release];

  if (argc > 1) {
    [NSApplication sharedApplication];
    char path[] = "/tmp/cot-winch-XXXXXX";
    int fd = mkstemp(path);
    expect(fd >= 0, "could not make a scratch file");
    close(fd);
    NSString *sizes = [NSString stringWithUTF8String:path];
    NSString *script = [NSString stringWithFormat:@"trap 'stty size >> %@' WINCH; while :; do sleep 0.05; done", sizes];
    COTTerminalConfiguration *shell = [[COTTerminalConfiguration defaultConfiguration] copy];
    [shell setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-c", script, nil]];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 400) styleMask:NSTitledWindowMask
                                                     backing:NSBackingStoreBuffered defer:NO];
    COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400) configuration:shell];
    [[window contentView] addSubview:view];
    NSError *error = nil;
    expect([view startTerminalWithError:&error], "the shell didn't start");
    spin(1.0);
    NSUInteger columns = [[view session] columns], rows = [[view session] rows];
    expect(columns > 20 && rows > 5, "the view should have sized the terminal");

    COTTerminalTheme *bigger = [[[[view session] configuration] theme] copy];
    CGFloat size = [bigger fontSize] * 2;
    [bigger setFontSize:size];
    [bigger setCursorStyle:COTTerminalCursorStyleBeam];
    [view applyTheme:bigger];
    // Re-measured now, not later: twice the font is about half the columns and rows.
    NSUInteger newColumns = [[view session] columns], newRows = [[view session] rows];
    expect(newColumns < columns * 0.7 && newRows < rows * 0.7, "applyTheme: should re-measure and resize at once");
    expect([[[[view session] configuration] theme] cursorStyle] == COTTerminalCursorStyleBeam, "the theme should apply");
    expect([[[view session] configuration] theme] != bigger, "the view keeps its own copy");
    [bigger setFontSize:6];
    expect([[[[view session] configuration] theme] fontSize] == size, "changing the caller's theme later changes nothing");
    spin(1.5);
    NSString *expected = [NSString stringWithFormat:@"%lu %lu", (unsigned long)newRows, (unsigned long)newColumns];
    expect([lastSize(sizes) isEqualToString:expected], "the program should get SIGWINCH with the new size");

    // Zoom is relative to the applied theme: Ctrl+0 comes back to it, not to the size the view started with.
    [view zoomIn];
    [view resetZoom];
    expect([[[[view session] configuration] theme] fontSize] == size, "resetZoom should return to the applied size");

    [bigger release];
    [[view session] terminate];
    [view removeFromSuperview];
    [view release];
    [window close];
    [shell release];
    unlink(path);
  }

  [configuration release];
  [pool drain];
  return 0;
}
