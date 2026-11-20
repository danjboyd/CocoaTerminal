// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// -PNGRepresentationWithError: shows output that has just arrived. The view marks itself dirty at most 30 times a second,
// so right after output the capture used to predate it (GNUstep reads the window's backing store): the demo's scenario
// screenshots were blank, cursor at the top left, while their text checks passed. Needs a display; skips without one.

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

// Pixels in the capture that are clearly red (the SGR 41 background, the theme's red: about #F0787F by default).
static NSInteger RedPixels(NSBitmapImageRep *bitmap) {
  NSInteger red = 0;
  for (NSInteger y = 0; y < [bitmap pixelsHigh]; y++)
    for (NSInteger x = 0; x < [bitmap pixelsWide]; x++) {
      NSColor *c = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
      if ([c redComponent] > 0.7 && [c redComponent] - [c greenComponent] > 0.3 && [c redComponent] - [c blueComponent] > 0.3) red++;
    }
  return red;
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
  COTTerminalTheme *theme = [configuration theme];
  [theme setForegroundColor:[NSColor whiteColor]];
  [theme setBackgroundColor:[NSColor blackColor]];
  // "ready", then on a line of input a red block.
  NSString *script = @"printf 'ready\\r\\n'; read x; printf '\\033[41mRED-RED-RED-RED\\033[0m\\r\\n'; exec sleep 30";
#if defined(_WIN32)
  NSString *shell = @"C:\\msys64\\usr\\bin\\sh.exe";  // MSYS2's, as the bench uses; COT_CAPTURE_TEST_SHELL overrides
#else
  NSString *shell = @"/bin/sh";
#endif
  if (getenv("COT_CAPTURE_TEST_SHELL")) shell = [NSString stringWithUTF8String:getenv("COT_CAPTURE_TEST_SHELL")];
  [configuration setShellCommand:[NSArray arrayWithObjects:shell, @"-c", script, nil]];
  NSRect frame = NSMakeRect(0, 0, 400, 120);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];
  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  COTTerminalSession *session = [view session];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0 && !AnyLineHasPrefix(session, @"ready"))
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  expect(AnyLineHasPrefix(session, @"ready"), "the first line arrives");
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];  // drawn and settled

  [session sendInput:[@"\r" dataUsingEncoding:NSUTF8StringEncoding]];
  // Watch in short slices so the capture comes well inside the view's 1/30 s update delay.
  deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0 && !AnyLineHasPrefix(session, @"RED-RED"))
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  expect(AnyLineHasPrefix(session, @"RED-RED"), "the red line arrives");
  NSData *png = [view PNGRepresentationWithError:&error];
  expect(png != nil, "a capture");
  if (getenv("COT_CAPTURE_TEST_PNG")) [png writeToFile:[NSString stringWithUTF8String:getenv("COT_CAPTURE_TEST_PNG")] atomically:YES];
  NSInteger red = RedPixels([NSBitmapImageRep imageRepWithData:png]);
  std::cout << "red pixels in the capture: " << red << "\n";
  expect(red > 100, "the capture shows the output that just arrived");

  [session terminate];
  [pool release];
  std::cout << "COTTerminalCaptureTests passed\n";
  return 0;
}
