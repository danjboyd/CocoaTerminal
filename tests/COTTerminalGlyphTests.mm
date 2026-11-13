// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// A character the terminal's font hasn't got (Claude Code's spinner: ✢ ✳ ✶ ✻ ✽ ●) draws in a covering font found
// through fontconfig, sized to its cell, instead of a "?"; the grid doesn't move. Needs a display and a font that lacks
// the glyphs (Intel One Mono; COT_GLYPH_TEST_FONT picks another); skips, passing, without them, and on macOS.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

@interface COTTerminalView (GlyphTesting)
- (NSFont *)fallbackFontFor:(NSString *)text font:(NSFont *)font cellWidth:(CGFloat)cellWidth lineHeight:(CGFloat)lineHeight;
@end

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

// The cell at (column, row) of the capture, as a string of grey levels.
static NSString *CellPixels(NSBitmapImageRep *bitmap, NSInteger column, NSInteger row, CGFloat cellWidth, CGFloat lineHeight,
                            NSEdgeInsets insets) {
  NSMutableString *out = [NSMutableString string];
  NSInteger x0 = (NSInteger)(insets.left + column * cellWidth), y0 = (NSInteger)(insets.top + row * lineHeight);
  for (NSInteger y = y0; y < y0 + (NSInteger)lineHeight; y++)
    for (NSInteger x = x0; x < x0 + (NSInteger)cellWidth; x++) {
      NSColor *c = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
      [out appendFormat:@"%d", (int)(([c redComponent] + [c greenComponent] + [c blueComponent]) * 3)];
    }
  return out;
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if defined(__APPLE__)
  std::cout << "skipped: Core Text cascades on its own\n";
  return 0;
#endif
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
  [NSApplication sharedApplication];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  COTTerminalTheme *theme = [configuration theme];
  [theme setFontFamily:getenv("COT_GLYPH_TEST_FONT") ? [NSString stringWithUTF8String:getenv("COT_GLYPH_TEST_FONT")] : @"Intel One Mono"];
  NSFont *font = [theme font];
  if ([[font coveredCharacterSet] longCharacterIsMember:0x2733]) {
    std::cout << "skipped: " << [[font fontName] UTF8String] << " has the spinner glyphs\n";
    return 0;
  }
  [theme setForegroundColor:[NSColor whiteColor]];
  [theme setBackgroundColor:[NSColor blackColor]];
  [configuration setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-c", @"printf '\\342\\234\\263?a\\r\\n'; exec sleep 30", nil]];
  NSRect frame = NSMakeRect(0, 0, 400, 120);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];

  CGFloat cellWidth = [@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;
  CGFloat lineHeight = [font ascender] - [font descender] + [theme lineSpacing];
  NSFont *fallback = [view fallbackFontFor:@"✳" font:font cellWidth:cellWidth lineHeight:lineHeight];
  std::cout << "font " << [[font fontName] UTF8String] << ", fallback for ✳: " << (fallback ? [[fallback fontName] UTF8String] : "none") << "\n";
  expect(fallback != nil && fallback != font, "a covering font for ✳");
  expect([[fallback coveredCharacterSet] longCharacterIsMember:0x2733], "…that has it");
  expect([@"✳" sizeWithAttributes:[NSDictionary dictionaryWithObject:fallback forKey:NSFontAttributeName]].width <= cellWidth + 0.5,
         "…no wider than the cell");
  expect([view fallbackFontFor:@"a" font:font cellWidth:cellWidth lineHeight:lineHeight] == nil, "none for a character the font has");

  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0 && ![[[[view session] visibleLines] firstObject] hasPrefix:@"✳?a"])
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  expect([[[[view session] visibleLines] firstObject] hasPrefix:@"✳?a"], "the line arrives");
  [view setNeedsDisplay:YES];
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:[view PNGRepresentationWithError:&error]];
  NSEdgeInsets insets = [theme contentInsets];
  NSString *spinner = CellPixels(bitmap, 0, 0, cellWidth, lineHeight, insets);
  NSString *question = CellPixels(bitmap, 1, 0, cellWidth, lineHeight, insets);
  NSString *letter = CellPixels(bitmap, 2, 0, cellWidth, lineHeight, insets);
  NSString *blank = CellPixels(bitmap, 5, 0, cellWidth, lineHeight, insets);
  expect(![spinner isEqual:blank], "the ✳ cell has ink");
  expect(![spinner isEqual:question], "…and it isn't a \"?\"");
  expect(![letter isEqual:blank], "the cells after it draw (the grid didn't move them off)");

  [[view session] terminate];
  [pool release];
  std::cout << "COTTerminalGlyphTests passed\n";
  return 0;
}
