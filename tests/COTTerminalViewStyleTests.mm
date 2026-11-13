// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// SGR 1 (bold) and 3 (italic) draw in the theme font's own bold and italic faces, on the same grid. Needs a display
// (run it under Xvfb); it skips, passing, when there is none. COT_STYLE_TEST_FONT picks another family.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

@interface COTTerminalView (StyleTesting)
- (NSFont *)fontForBold:(BOOL)bold italic:(BOOL)italic;
@end

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

static CGFloat advanceOf(NSFont *font) {
  return [@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;
}

// Summed brightness of the pixels in one text row of the capture (row 0 at the top).
static double inkInRow(NSBitmapImageRep *bitmap, NSInteger row, CGFloat lineHeight, CGFloat topInset) {
  double ink = 0.0;
  NSInteger y0 = (NSInteger)(topInset + row * lineHeight), y1 = (NSInteger)(topInset + (row + 1) * lineHeight);
  for (NSInteger y = y0; y < y1 && y < [bitmap pixelsHigh]; ++y) {
    for (NSInteger x = 0; x < [bitmap pixelsWide]; ++x) {
      NSColor *c = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
      ink += ([c redComponent] + [c greenComponent] + [c blueComponent]) / 3.0;
    }
  }
  return ink;
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
  if (getenv("COT_STYLE_TEST_FONT")) [theme setFontFamily:[NSString stringWithUTF8String:getenv("COT_STYLE_TEST_FONT")]];
  [configuration setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-c",
    @"printf '\\033[1mMMMMMMMMMMMMMMMMMMMM\\033[0m\\r\\nMMMMMMMMMMMMMMMMMMMM\\r\\n\\033[3mMMMMMMMMMMMMMMMMMMMM\\033[0m\\r\\n'; sleep 30", nil]];

  NSRect frame = NSMakeRect(0, 0, 640, 200);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];

  NSFont *regular = [theme font];
  NSFont *bold = [view fontForBold:YES italic:NO];
  NSFont *italic = [view fontForBold:NO italic:YES];
  NSFontManager *manager = [NSFontManager sharedFontManager];
  std::cout << "regular " << [[regular fontName] UTF8String] << ", bold " << [[bold fontName] UTF8String]
            << ", italic " << [[italic fontName] UTF8String] << "\n";
  expect([view fontForBold:NO italic:NO] == regular, "plain cells should use the theme font");
  expect(bold != regular && ([manager traitsOfFont:bold] & NSBoldFontMask), "bold cells should use the bold face");
  expect(fabs(advanceOf(bold) - advanceOf(regular)) < 0.5, "the bold face must keep the grid's advance");
  if (italic != regular) {
    expect([manager traitsOfFont:italic] & NSItalicFontMask, "italic cells should use an italic face");
    expect(fabs(advanceOf(italic) - advanceOf(regular)) < 0.5, "the italic face must keep the grid's advance");
  }

  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  COTTerminalSession *session = [view session];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while ([deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSArray *lines = [session visibleLines];
    if ([lines count] >= 3 && [[lines objectAtIndex:2] hasPrefix:@"MMMMMMMMMMMMMMMMMMMM"]) break;
  }
  expect([[[session visibleLines] objectAtIndex:2] hasPrefix:@"MMMM"], "the fixture's output should arrive");
  NSArray *rows = [session styledVisibleRows];
  std::cout << "row 0 run: " << [[[[rows objectAtIndex:0] objectAtIndex:0] description] UTF8String] << "\n";

  [view setNeedsDisplay:YES];
  NSData *png = [view PNGRepresentationWithError:&error];
  expect(png != nil, "capture failed");
  if (getenv("COT_STYLE_TEST_PNG")) [png writeToFile:[NSString stringWithUTF8String:getenv("COT_STYLE_TEST_PNG")] atomically:YES];
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:png];
  CGFloat lineHeight = [regular ascender] - [regular descender] + [theme lineSpacing];
  CGFloat top = [theme contentInsets].top;
  double boldInk = inkInRow(bitmap, 0, lineHeight, top), plainInk = inkInRow(bitmap, 1, lineHeight, top);
  std::cout << "ink: bold row " << boldInk << ", plain row " << plainInk << "\n";
  expect(plainInk > 0, "the plain row should have ink");
  expect(boldInk > plainInk * 1.15, "the bold row should draw heavier than the plain row");

  [[view session] terminate];
  [pool release];
  std::cout << "COTTerminalViewStyleTests passed\n";
  return 0;
}
