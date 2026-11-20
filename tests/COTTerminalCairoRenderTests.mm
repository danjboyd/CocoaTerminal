// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// The Cairo renderer, as good as the OpenGL one: box drawing joins between rows (a font's │ stops short of the cell once
// there's line spacing, so a vertical line had a gap at every row), and an emoji above the BMP (🚀) is drawn rather
// than left blank (GNUstep's Cairo backend draws glyphs as UTF-16 units, so it can't). Needs a display; skips without.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cmath>
#include <cstdio>
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

struct Pixel {
  double r, g, b;
};

static Pixel PixelAt(NSBitmapImageRep *bitmap, NSInteger x, NSInteger y) {
  NSColor *c = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  return Pixel{[c redComponent], [c greenComponent], [c blueComponent]};
}

// A failed check that lets the others run, so one run reports both.
static int failures = 0;
static void check(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    failures++;
  }
}

static BOOL Lit(Pixel p) { return (p.r + p.g + p.b) / 3 > 0.5; }           // the white foreground, on black
static BOOL NotBackground(Pixel p) { return p.r + p.g + p.b > 0.15; }
static BOOL Colourful(Pixel p) { return fmax(p.r, fmax(p.g, p.b)) - fmin(p.r, fmin(p.g, p.b)) > 0.25; }

// Whether fontconfig has a colour font with 🚀 (Noto Color Emoji, say). Without one a monochrome glyph will do.
static BOOL ColourEmojiFontInstalled(void) {
#if !defined(__APPLE__) && !defined(_WIN32)
  FILE *list = popen("fc-list ':charset=1f680:color=true' family 2>/dev/null", "r");
  if (list == NULL) return NO;
  char line[256];
  BOOL found = fgets(line, sizeof line, list) != NULL;
  pclose(list);
  return found;
#else
  return YES;
#endif
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if !defined(__APPLE__) && !defined(_WIN32)
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
#endif
  setenv("COCOATERMINAL_RENDERER", "cairo", 1);
  [NSApplication sharedApplication];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  [configuration setRenderer:COTTerminalRendererCairo];
  COTTerminalTheme *theme = [configuration theme];
  [theme setForegroundColor:[NSColor whiteColor]];
  [theme setBackgroundColor:[NSColor blackColor]];
  // Rows 0-5: │ in column 0. Row 6: 🚀 in columns 2-3. Then END.
  NSString *script = @"i=0; while [ $i -lt 6 ]; do printf '\\342\\224\\202\\r\\n'; i=$((i+1)); done; "
                     @"printf '  \\360\\237\\232\\200\\r\\nEND\\r\\n'; exec sleep 30";
  [configuration setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-c", script, nil]];
  NSRect frame = NSMakeRect(0, 0, 400, 240);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];
  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  COTTerminalSession *session = [view session];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
  while ([deadline timeIntervalSinceNow] > 0 && !AnyLineHasPrefix(session, @"END"))
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  expect(AnyLineHasPrefix(session, @"END"), "the output arrives");
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
  NSData *png = [view PNGRepresentationWithError:&error];
  expect(png != nil, "a capture");
  if (getenv("COT_CAIRO_TEST_PNG")) [png writeToFile:[NSString stringWithUTF8String:getenv("COT_CAIRO_TEST_PNG")] atomically:YES];
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:png];
  expect([[[view performanceSnapshot] objectForKey:@"renderer"] isEqual:@"cairo"], "drawn with Cairo");

  // The cell grid as the view lays it out (y down from the top of the capture).
  theme = [[session configuration] theme];
  NSFont *font = [theme font];
  NSEdgeInsets insets = [theme contentInsets];
  double scale = [bitmap pixelsHigh] / NSHeight([view bounds]);
  double cellWidth = [@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width * scale;
  double lineHeight = ([font ascender] - [font descender] + [theme lineSpacing]) * scale;
  double left = insets.left * scale, top = insets.top * scale;

  // (a) The column of │: the pixel column with the most lit pixels in column 0, rows 0-5. From the middle of row 0 to
  // the middle of row 5 every pixel is lit: no gap between rows.
  NSInteger bestX = -1, bestCount = -1;
  for (NSInteger x = (NSInteger)floor(left); x < (NSInteger)ceil(left + cellWidth); x++) {
    NSInteger count = 0;
    for (NSInteger y = (NSInteger)top; y < (NSInteger)(top + 6 * lineHeight); y++)
      if (Lit(PixelAt(bitmap, x, y))) count++;
    if (count > bestCount) bestCount = count, bestX = x;
  }
  NSInteger gaps = 0;
  NSInteger from = (NSInteger)(top + lineHeight / 2), to = (NSInteger)(top + 5.5 * lineHeight);
  for (NSInteger y = from; y < to; y++)
    if (!Lit(PixelAt(bitmap, bestX, y))) gaps++;
  std::cout << "vertical line at x=" << bestX << ": " << gaps << " gap pixels in " << (to - from) << "\n";
  expect(bestCount > 0, "the vertical line is drawn");
  check(gaps == 0, "a vertical box line has no gaps between rows");

  // (b) The emoji cell (row 6, columns 2-3) is not blank; in colour when a colour emoji font draws it.
  NSInteger drawn = 0, colourful = 0;
  for (NSInteger y = (NSInteger)(top + 6 * lineHeight); y < (NSInteger)(top + 7 * lineHeight); y++)
    for (NSInteger x = (NSInteger)(left + 2 * cellWidth); x < (NSInteger)(left + 4 * cellWidth); x++) {
      Pixel p = PixelAt(bitmap, x, y);
      if (NotBackground(p)) drawn++;
      if (Colourful(p)) colourful++;
    }
  std::cout << "emoji cell: " << drawn << " drawn pixels, " << colourful << " in colour\n";
  check(drawn > 20, "an emoji cell is not blank");
  if (ColourEmojiFontInstalled()) check(colourful > 20, "the emoji is in colour (a colour emoji font is installed)");

  [session terminate];
  [pool release];
  if (failures) return 1;
  std::cout << "COTTerminalCairoRenderTests passed\n";
  return 0;
}
