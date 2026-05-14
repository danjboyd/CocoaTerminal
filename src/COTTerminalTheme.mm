// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalTheme.h>

static NSColor *COTColorFromHex(unsigned int hex) {
  CGFloat red = ((hex >> 16) & 0xff) / 255.0;
  CGFloat green = ((hex >> 8) & 0xff) / 255.0;
  CGFloat blue = (hex & 0xff) / 255.0;
  return [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0];
}

// On GNUstep, NSFont's point size is interpreted at 72 DPI by default
// (legacy AppKit behavior). Most X displays report 96 DPI, and other
// terminals (Alacritty, kitty, gnome-terminal) interpret their `size`
// values at the display DPI. To keep "size = 13" visually equivalent
// across our app and those, scale the requested points by the ratio.
// Override via the COCOATERMINAL_FONT_DPI env var (default: 96).
static CGFloat COTGNUstepFontScale(void) {
#if defined(__APPLE__)
  return 1.0;
#else
  static CGFloat cached = 0.0;
  if (cached == 0.0) {
    const char *override_ = getenv("COCOATERMINAL_FONT_DPI");
    double dpi = 96.0;
    if (override_ != NULL) {
      double parsed = atof(override_);
      if (parsed > 0) dpi = parsed;
    }
    cached = (CGFloat)(dpi / 72.0);
  }
  return cached;
#endif
}

static NSFont *COTFontWithFamily(NSString *family, CGFloat size) {
  CGFloat scaled = size * COTGNUstepFontScale();
  NSFont *font = [NSFont fontWithName:family size:scaled];
  if (font == nil && [family isEqualToString:@"Intel One Mono"]) {
    font = [NSFont fontWithName:@"IntelOneMono-Regular" size:scaled];
  }
  if (font == nil) {
    font = [NSFont userFixedPitchFontOfSize:scaled];
  }
  if (font == nil) {
    font = [NSFont systemFontOfSize:scaled];
  }
  return font;
}

@interface COTTerminalTheme () {
  NSFont *_font;
}
@end

@implementation COTTerminalTheme

+ (instancetype)defaultTheme {
  return [self alacrittyInspiredDarkTheme];
}

+ (instancetype)alacrittyInspiredDarkTheme {
  COTTerminalTheme *theme = [[[self alloc] init] autorelease];
  theme.name = @"Alacritty Inspired Dark";
  theme.fontFamily = @"Intel One Mono";
  theme.fontSize = 13.0;
  theme.backgroundColor = COTColorFromHex(0x181818);
  theme.foregroundColor = COTColorFromHex(0xe6e1dc);
  theme.cursorColor = COTColorFromHex(0x79c7c5);
  theme.cursorStyle = COTTerminalCursorStyleBlock;
  theme.selectionColor = COTColorFromHex(0x2b3339);
  theme.ansiColors = [NSArray arrayWithObjects:
    COTColorFromHex(0x181818),
    COTColorFromHex(0xf07178),
    COTColorFromHex(0xc3e88d),
    COTColorFromHex(0xffcb6b),
    COTColorFromHex(0x82aaff),
    COTColorFromHex(0xc792ea),
    COTColorFromHex(0x89ddff),
    COTColorFromHex(0xe6e1dc),
    COTColorFromHex(0x5f6368),
    COTColorFromHex(0xff8b92),
    COTColorFromHex(0xddffa7),
    COTColorFromHex(0xffe585),
    COTColorFromHex(0x9cc4ff),
    COTColorFromHex(0xe1acff),
    COTColorFromHex(0xa3f7ff),
    COTColorFromHex(0xffffff),
    nil];
  theme.contentInsets = NSEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);
  theme.lineSpacing = 2.0;
  theme.opacity = 1.0;
  return theme;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _name = [@"Custom" copy];
    _fontFamily = [@"Monospace" copy];
    _fontSize = 13.0;
    _foregroundColor = [COTColorFromHex(0xe6e1dc) retain];
    _backgroundColor = [COTColorFromHex(0x181818) retain];
    _cursorColor = [COTColorFromHex(0x79c7c5) retain];
    _cursorStyle = COTTerminalCursorStyleBlock;
    _selectionColor = [COTColorFromHex(0x2b3339) retain];
    _ansiColors = [[NSArray alloc] init];
    _contentInsets = NSEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);
    _lineSpacing = 2.0;
    _opacity = 1.0;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  COTTerminalTheme *copy = [[[self class] allocWithZone:zone] init];
  copy.name = self.name;
  copy.fontFamily = self.fontFamily;
  copy.fontSize = self.fontSize;
  copy.font = _font;
  copy.foregroundColor = self.foregroundColor;
  copy.backgroundColor = self.backgroundColor;
  copy.cursorColor = self.cursorColor;
  copy.cursorStyle = self.cursorStyle;
  copy.selectionColor = self.selectionColor;
  copy.ansiColors = self.ansiColors;
  copy.contentInsets = self.contentInsets;
  copy.lineSpacing = self.lineSpacing;
  copy.opacity = self.opacity;
  return copy;
}

- (void)setFontFamily:(NSString *)fontFamily {
  if (_fontFamily != fontFamily) {
    [_fontFamily release];
    _fontFamily = [fontFamily copy];
    [_font release];
    _font = nil;
  }
}

- (void)setFontSize:(CGFloat)fontSize {
  _fontSize = fontSize;
  [_font release];
  _font = nil;
}

- (NSFont *)font {
  if (_font == nil) {
    _font = [COTFontWithFamily(_fontFamily, _fontSize) retain];
  }
  return _font;
}

- (void)setFont:(NSFont *)font {
  if (_font != font) {
    [_font release];
    _font = [font retain];
  }
}

- (void)dealloc {
  [_name release];
  [_fontFamily release];
  [_font release];
  [_foregroundColor release];
  [_backgroundColor release];
  [_cursorColor release];
  [_selectionColor release];
  [_ansiColors release];
  [super dealloc];
}

@synthesize name = _name;
@synthesize fontFamily = _fontFamily;
@synthesize fontSize = _fontSize;
@synthesize foregroundColor = _foregroundColor;
@synthesize backgroundColor = _backgroundColor;
@synthesize cursorColor = _cursorColor;
@synthesize cursorStyle = _cursorStyle;
@synthesize selectionColor = _selectionColor;
@synthesize ansiColors = _ansiColors;
@synthesize contentInsets = _contentInsets;
@synthesize lineSpacing = _lineSpacing;
@synthesize opacity = _opacity;

@end
