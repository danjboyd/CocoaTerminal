// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// SGR 2 (dim), 9 (strikethrough) and 8 (hidden) as drawn: white on black, a dim row's brightest pixel is about half
// way, a struck-through row of spaces has a line across it, and a hidden row has no ink. Needs a display (run it under
// Xvfb); skips, passing, without one.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

static double Brightness(NSBitmapImageRep *bitmap, NSInteger x, NSInteger y) {
  NSColor *c = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  return ([c redComponent] + [c greenComponent] + [c blueComponent]) / 3.0;
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
  [NSApplication sharedApplication];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  COTTerminalTheme *theme = [configuration theme];
  [theme setForegroundColor:[NSColor whiteColor]];
  [theme setBackgroundColor:[NSColor blackColor]];
  [configuration setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-c",
    @"printf 'MMMMMMMM\\r\\n\\033[2mMMMMMMMM\\033[0m\\r\\n\\033[9m        \\033[0m\\r\\n\\033[8mMMMMMMMM\\033[0m\\r\\n'; exec sleep 30", nil]];
  NSRect frame = NSMakeRect(0, 0, 400, 160);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];
  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0 && [[[view session] visibleLines] count] > 3 &&
         ![[[[view session] visibleLines] objectAtIndex:3] hasPrefix:@"MMMM"])
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  [view setNeedsDisplay:YES];
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:[view PNGRepresentationWithError:&error]];
  NSFont *font = [theme font];
  CGFloat cellWidth = [@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;
  CGFloat lineHeight = [font ascender] - [font descender] + [theme lineSpacing];
  NSEdgeInsets insets = [theme contentInsets];
  double maxIn[4] = {0, 0, 0, 0};
  NSInteger brightRows[4] = {0, 0, 0, 0};  // pixel rows lit across most of the 8 cells (the strike line)
  for (int row = 0; row < 4; row++) {
    NSInteger y0 = (NSInteger)(insets.top + row * lineHeight);
    for (NSInteger y = y0; y < y0 + (NSInteger)lineHeight; y++) {
      NSInteger lit = 0;
      for (NSInteger x = (NSInteger)insets.left; x < (NSInteger)(insets.left + 8 * cellWidth); x++) {
        double b = Brightness(bitmap, x, y);
        if (b > maxIn[row]) maxIn[row] = b;
        if (b > 0.6) lit++;
      }
      if (lit > 6 * cellWidth) brightRows[row]++;
    }
  }
  std::cout << "brightest: normal " << maxIn[0] << ", dim " << maxIn[1] << ", strike " << maxIn[2] << ", hidden " << maxIn[3]
            << "; strike lines " << brightRows[2] << "\n";
  expect(maxIn[0] > 0.9, "the normal row is white");
  expect(maxIn[1] > 0.3 && maxIn[1] < 0.7, "the dim row is about half way to the background");
  expect(brightRows[2] >= 1, "the struck-through spaces have a line across them");
  expect(maxIn[3] < 0.1, "the hidden row has no ink");

  [[view session] terminate];
  [pool release];
  std::cout << "COTTerminalAttributeTests passed\n";
  return 0;
}
