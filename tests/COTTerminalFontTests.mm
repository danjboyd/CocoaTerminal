// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// A theme's fontFamily takes any installed monospaced family by its family name, the way other terminals' configs do,
// not only the ones whose PostScript name happens to be the same ("Courier New" is CourierNewPSMT). Needs a display;
// skips, passing, without one.

#import <CocoaTerminal/CocoaTerminal.h>
#import <AppKit/AppKit.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, NSString *message) {
  if (!condition) {
    std::cerr << "FAIL: " << [message UTF8String] << "\n";
    std::exit(1);
  }
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if !defined(_WIN32) && !defined(__APPLE__)
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
#endif
  [NSApplication sharedApplication];
  NSFontManager *manager = [NSFontManager sharedFontManager];

  // Every monospaced family installed: those are what a terminal theme names.
  NSMutableSet *families = [NSMutableSet set];
  for (NSString *name in [manager availableFontNamesWithTraits:NSFixedPitchFontMask]) {
    NSString *family = [[NSFont fontWithName:name size:12] familyName];
    if (family != nil) [families addObject:family];
  }
  expect([families count] > 0, @"no installed monospaced families to try");

  NSUInteger tried = 0;
  for (NSString *family in [[families allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
    // Only families with a regular face: a theme names a family and gets its regular weight.
    if ([manager fontWithFamily:family traits:0 weight:5 size:12] == nil) continue;
    COTTerminalTheme *theme = [[COTTerminalTheme alloc] init];
    [theme setFontFamily:family];
    NSFont *font = [theme font];
    expect([[font familyName] isEqualToString:family],
           [NSString stringWithFormat:@"fontFamily \"%@\" gave %@ (%@)", family, [font fontName], [font familyName]]);
    std::cout << [family UTF8String] << " -> " << [[font fontName] UTF8String] << "\n";
    [theme release];
    tried++;
  }
  expect(tried > 0, @"no family with a regular face");
  std::cout << tried << " families\n";
  [pool drain];
  return 0;
}
