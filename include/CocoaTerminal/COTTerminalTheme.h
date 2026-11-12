// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTPlatform.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, COTTerminalCursorStyle) {
  COTTerminalCursorStyleBlock = 0,
  COTTerminalCursorStyleBeam = 1,
  COTTerminalCursorStyleUnderline = 2,
};

@interface COTTerminalTheme : NSObject <NSCopying>

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fontFamily;
@property (nonatomic) CGFloat fontSize;
@property (nonatomic, retain) NSFont *font;
@property (nonatomic, retain) NSColor *foregroundColor;
@property (nonatomic, retain) NSColor *backgroundColor;
@property (nonatomic, retain) NSColor *cursorColor;
@property (nonatomic) COTTerminalCursorStyle cursorStyle;
@property (nonatomic, retain) NSColor *selectionColor;
@property (nonatomic, copy) NSArray<NSColor *> *ansiColors;
@property (nonatomic) NSEdgeInsets contentInsets;
@property (nonatomic) CGFloat lineSpacing;
@property (nonatomic) CGFloat opacity;

+ (instancetype)defaultTheme;
+ (instancetype)alacrittyInspiredDarkTheme;
/// xterm's standard colour for palette indices 16-255 (the 6x6x6 cube, then 24 greys); nil outside that range.
/// Drawing uses it for any index the theme's ansiColors doesn't cover, so a 16-colour palette keeps the 256-colour range.
+ (nullable NSColor *)xtermColorAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
