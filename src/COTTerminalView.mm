// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalTheme.h>
#import <CocoaTerminal/COTTerminalView.h>

#import "COTTerminalSessionInternal.h"

#include <math.h>

static NSString *const COTTerminalViewErrorDomain = @"COTTerminalViewErrorDomain";

static NSColor *COTColorFromTerminalColor(const cot::TerminalColor &color, COTTerminalTheme *theme, BOOL foreground) {
  switch (color.kind) {
  case cot::TerminalColor::Kind::Palette: {
    NSArray *colors = [theme ansiColors];
    if (color.index >= 0 && color.index < (int)[colors count]) {
      return [colors objectAtIndex:(NSUInteger)color.index];
    }
    break;
  }
  case cot::TerminalColor::Kind::RGB:
    return [NSColor colorWithCalibratedRed:color.red / 255.0
                                     green:color.green / 255.0
                                      blue:color.blue / 255.0
                                     alpha:1.0];
  case cot::TerminalColor::Kind::Default:
    break;
  }
  return foreground ? [theme foregroundColor] : [theme backgroundColor];
}

@interface COTTerminalView () {
  COTTerminalSession *_session;
  NSDictionary *_textAttributes;
  CGFloat _baseFontSize;
  CGFloat _cellWidth;
  CGFloat _lineHeight;
  int _activeMouseButton;
  BOOL _hasSelection;
  NSInteger _selectionAnchorRow;
  NSInteger _selectionAnchorColumn;
  NSInteger _selectionCurrentRow;
  NSInteger _selectionCurrentColumn;
  BOOL _selectingLocally;
}
@end

@implementation COTTerminalView

- (instancetype)initWithFrame:(NSRect)frameRect {
  return [self initWithFrame:frameRect configuration:[COTTerminalConfiguration defaultConfiguration]];
}

- (instancetype)initWithFrame:(NSRect)frameRect configuration:(COTTerminalConfiguration *)configuration {
  self = [super initWithFrame:frameRect];
  if (self) {
    _session = [[COTTerminalSession alloc] initWithConfiguration:configuration];
    [_session setDelegate:self];
    _baseFontSize = [[[configuration theme] font] pointSize];
    _activeMouseButton = -1;
    [self rebuildTextAttributes];
    [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self setPostsFrameChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(viewFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:self];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    _session = [[COTTerminalSession alloc] initWithConfiguration:[COTTerminalConfiguration defaultConfiguration]];
    [_session setDelegate:self];
    _baseFontSize = [[[[_session configuration] theme] font] pointSize];
    _activeMouseButton = -1;
    [self rebuildTextAttributes];
    [self setPostsFrameChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(viewFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:self];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_session release];
  [_textAttributes release];
  [super dealloc];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  static int debugKeys = -1;
  if (debugKeys < 0) {
    debugKeys = getenv("COTTERMINAL_DEBUG_KEYS") != NULL ? 1 : 0;
  }
  if (debugKeys) {
    NSString *chars = [event charactersIgnoringModifiers] ?: @"";
    fprintf(stderr,
            "[COT performKeyEq] flags=0x%08lx keyCode=%u base='%s' firstResponder=%s\n",
            (unsigned long)[event modifierFlags],
            (unsigned)[event keyCode],
            [chars UTF8String],
            [[self window] firstResponder] == self ? "self" : "other");
    fflush(stderr);
  }

  // Clipboard shortcuts wired without a menubar (Alacritty-style). Require
  // Cmd+Shift so we never collide with terminal-control Ctrl+letter byte
  // translation in keyDown:.
  NSUInteger flags = [event modifierFlags];
  if ((flags & NSCommandKeyMask) && (flags & NSShiftKeyMask)) {
    NSString *base = [[event charactersIgnoringModifiers] lowercaseString];
    if ([base isEqualToString:@"c"]) {
      [self copySelection];
      return YES;
    }
    if ([base isEqualToString:@"v"]) {
      [self pasteFromClipboard];
      return YES;
    }
    if ([base isEqualToString:@"a"]) {
      [self selectAll];
      return YES;
    }
  }

  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  [self setNeedsDisplay:YES];
  if ([_session isFocusReportingEnabled]) {
    [_session sendInput:[@"\033[I" dataUsingEncoding:NSUTF8StringEncoding]];
  }
  return YES;
}

- (BOOL)resignFirstResponder {
  [self setNeedsDisplay:YES];
  if ([_session isFocusReportingEnabled]) {
    [_session sendInput:[@"\033[O" dataUsingEncoding:NSUTF8StringEncoding]];
  }
  return YES;
}

- (BOOL)startTerminalWithError:(NSError **)error {
  [self updateTerminalSizeFromBounds];
  return [_session startWithError:error];
}

- (NSData *)PNGRepresentationWithError:(NSError **)error {
  NSRect bounds = [self bounds];
  if (NSIsEmptyRect(bounds)) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:COTTerminalViewErrorDomain
                                   code:1
                               userInfo:[NSDictionary dictionaryWithObject:@"Cannot capture an empty terminal view."
                                                                    forKey:NSLocalizedDescriptionKey]];
    }
    return nil;
  }

  [self displayIfNeeded];
  NSBitmapImageRep *bitmap = [self bitmapImageRepForCachingDisplayInRect:bounds];
  if (bitmap == nil) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:COTTerminalViewErrorDomain
                                   code:2
                               userInfo:[NSDictionary dictionaryWithObject:@"Failed to allocate a bitmap image representation."
                                                                    forKey:NSLocalizedDescriptionKey]];
    }
    return nil;
  }

  [self cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
  NSData *data = [bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
  if (data == nil || [data length] == 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:COTTerminalViewErrorDomain
                                   code:3
                               userInfo:[NSDictionary dictionaryWithObject:@"Failed to encode terminal view as PNG."
                                                                    forKey:NSLocalizedDescriptionKey]];
    }
    return nil;
  }

  return data;
}

- (void)drawRect:(NSRect)dirtyRect {
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSColor *backgroundColor = [theme backgroundColor];
  if ([theme opacity] < 1.0) {
    backgroundColor = [backgroundColor colorWithAlphaComponent:[theme opacity]];
  }
  [backgroundColor setFill];
  NSRectFill(dirtyRect);

  const cot::TerminalGrid *grid = [_session gridPointer];
  if (grid == NULL) {
    return;
  }
  std::vector<std::vector<cot::TerminalCell>> ownedRows;
  const std::vector<std::vector<cot::TerminalCell>> *rowsPtr = NULL;
  if ([_session viewportOffset] == 0) {
    rowsPtr = &grid->visibleCells();
  } else {
    ownedRows = grid->viewportCells();
    rowsPtr = &ownedRows;
  }
  const std::vector<std::vector<cot::TerminalCell>> &rows = *rowsPtr;

  NSEdgeInsets insets = [theme contentInsets];
  NSFont *font = [theme font];
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : [font ascender] - [font descender] + [theme lineSpacing];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : [@"M" sizeWithAttributes:_textAttributes].width;
  CGFloat y = NSMaxY([self bounds]) - insets.top - lineHeight;
  CGFloat firstBaselineY = y;

  NSInteger selStartRow = 0, selStartCol = 0, selEndRow = 0, selEndCol = 0;
  BOOL drawSelection = _hasSelection;
  if (drawSelection) {
    [self normalizedSelectionStartRow:&selStartRow startColumn:&selStartCol endRow:&selEndRow endColumn:&selEndCol];
  }
  NSColor *selectionColor = [theme selectionColor];
  NSColor *defaultForeground = [theme foregroundColor];

  for (NSInteger rowIndex = 0; rowIndex < (NSInteger)rows.size(); ++rowIndex) {
    if (!(y + lineHeight >= NSMinY(dirtyRect) && y <= NSMaxY(dirtyRect))) {
      y -= lineHeight;
      if (y < NSMinY([self bounds]) + insets.bottom) {
        break;
      }
      continue;
    }
    const std::vector<cot::TerminalCell> &row = rows[(std::size_t)rowIndex];

    CGFloat x = insets.left;
    NSInteger columnIndex = 0;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    CGFloat lineStartX = x;

    for (std::size_t i = 0; i < row.size(); ++i) {
      const cot::TerminalCell &cell = row[i];
      if (cell.continuation) {
        columnIndex += 1;
        continue;
      }
      int cellWidthCells = std::max(1, cell.width);
      CGFloat cellRectWidth = cellWidth * cellWidthCells;
      NSColor *foreground = COTColorFromTerminalColor(cell.attributes.foreground, theme, YES);
      NSColor *background = COTColorFromTerminalColor(cell.attributes.background, theme, NO);
      BOOL defaultBackground = (cell.attributes.background.kind == cot::TerminalColor::Kind::Default);
      if (cell.attributes.inverse) {
        NSColor *swapped = foreground;
        foreground = background;
        background = swapped;
        defaultBackground = NO;
      }
      BOOL inSelection = NO;
      if (drawSelection) {
        NSInteger firstColInRow = (rowIndex == selStartRow) ? selStartCol : 0;
        NSInteger lastColInRow = (rowIndex == selEndRow) ? selEndCol : (NSInteger)row.size();
        inSelection = (rowIndex >= selStartRow && rowIndex <= selEndRow &&
                       columnIndex >= firstColInRow && columnIndex < lastColInRow);
      }
      if (inSelection) {
        [selectionColor setFill];
        NSRectFill(NSMakeRect(x, y, cellRectWidth, lineHeight));
      } else if (!defaultBackground) {
        [background setFill];
        NSRectFill(NSMakeRect(x, y, cellRectWidth, lineHeight));
      }

      NSString *text = [[NSString alloc] initWithBytes:cell.text.data()
                                                length:cell.text.size()
                                              encoding:NSUTF8StringEncoding];
      if (text == nil) {
        text = [@" " retain];
      }
      NSDictionary *attrs = (foreground == defaultForeground)
        ? _textAttributes
        : @{NSFontAttributeName: font, NSForegroundColorAttributeName: foreground};
      NSAttributedString *piece = [[NSAttributedString alloc] initWithString:text attributes:attrs];
      [line appendAttributedString:piece];
      [piece release];
      [text release];

      if (cell.attributes.underline) {
        [foreground setFill];
        NSRectFill(NSMakeRect(x, y, cellRectWidth, 1.0));
      }

      x += cellRectWidth;
      columnIndex += cellWidthCells;
    }
    [line drawAtPoint:NSMakePoint(lineStartX, y)];
    [line release];
    y -= lineHeight;
    if (y < NSMinY([self bounds]) + insets.bottom) {
      break;
    }
  }

  if ([_session viewportOffset] == 0 && [[self window] firstResponder] == self && [_session isCursorVisible]) {
    CGFloat cursorX = insets.left + (CGFloat)[_session cursorColumn] * cellWidth;
    CGFloat cursorY = firstBaselineY - (CGFloat)[_session cursorRow] * lineHeight;
    NSRect cursorRect = NSMakeRect(cursorX, cursorY, cellWidth, lineHeight);
    COTTerminalCursorStyle style = [theme cursorStyle];
    cot::TerminalCursorShape pty = grid->cursorShape();
    if (pty == cot::TerminalCursorShape::Bar) {
      style = COTTerminalCursorStyleBeam;
    } else if (pty == cot::TerminalCursorShape::Underline) {
      style = COTTerminalCursorStyleUnderline;
    } else if (pty == cot::TerminalCursorShape::Block) {
      // honor theme choice when libvterm reports default block
    }
    if (style == COTTerminalCursorStyleBeam) {
      [[theme cursorColor] setFill];
      NSRectFill(NSMakeRect(cursorX, cursorY, 2.0, lineHeight));
    } else if (style == COTTerminalCursorStyleUnderline) {
      [[theme cursorColor] setFill];
      NSRectFill(NSMakeRect(cursorX, cursorY + lineHeight - 2.0, cellWidth, 2.0));
    } else {
      [[theme cursorColor] setFill];
      NSRectFill(cursorRect);
      NSUInteger cursorRow = [_session cursorRow];
      NSUInteger cursorColumn = [_session cursorColumn];
      NSString *cursorText = @" ";
      if (cursorRow < grid->rows() && cursorColumn < grid->columns()) {
        const cot::TerminalCell &cell = grid->visibleCells()[cursorRow][cursorColumn];
        if (!cell.continuation && !cell.text.empty()) {
          NSString *temp = [[NSString alloc] initWithBytes:cell.text.data()
                                                    length:cell.text.size()
                                                  encoding:NSUTF8StringEncoding];
          if (temp != nil) {
            cursorText = [temp autorelease];
          }
        }
      }
      NSMutableDictionary *cursorAttributes = [NSMutableDictionary dictionaryWithDictionary:_textAttributes];
      [cursorAttributes setObject:[theme backgroundColor] forKey:NSForegroundColorAttributeName];
      [cursorText drawAtPoint:NSMakePoint(cursorX, cursorY) withAttributes:cursorAttributes];
    }
  }
}

- (void)keyDown:(NSEvent *)event {
  static int debugKeys = -1;
  if (debugKeys < 0) {
    debugKeys = getenv("COTTERMINAL_DEBUG_KEYS") != NULL ? 1 : 0;
  }
  if (debugKeys) {
    NSString *chars = [event characters] ?: @"";
    NSString *baseChars = [event charactersIgnoringModifiers] ?: @"";
    NSMutableString *charsHex = [NSMutableString string];
    for (NSUInteger i = 0; i < [chars length]; ++i) {
      [charsHex appendFormat:@"%02x ", (unsigned int)[chars characterAtIndex:i]];
    }
    NSMutableString *baseHex = [NSMutableString string];
    for (NSUInteger i = 0; i < [baseChars length]; ++i) {
      [baseHex appendFormat:@"%02x ", (unsigned int)[baseChars characterAtIndex:i]];
    }
    fprintf(stderr,
            "[COT keyDown] flags=0x%08lx keyCode=%u chars='%s' (%s) base='%s' (%s)\n",
            (unsigned long)[event modifierFlags],
            (unsigned)[event keyCode],
            [chars UTF8String],
            [charsHex UTF8String],
            [baseChars UTF8String],
            [baseHex UTF8String]);
    fflush(stderr);
  }

  if ([self handleClipboardShortcut:event]) {
    if (debugKeys) { fprintf(stderr, "[COT keyDown]   -> consumed by clipboard shortcut\n"); fflush(stderr); }
    return;
  }
  if ([self handleZoomShortcut:event]) {
    if (debugKeys) { fprintf(stderr, "[COT keyDown]   -> consumed by zoom shortcut\n"); fflush(stderr); }
    return;
  }
  if ([self handleScrollbackShortcut:event]) {
    if (debugKeys) { fprintf(stderr, "[COT keyDown]   -> consumed by scrollback shortcut\n"); fflush(stderr); }
    return;
  }
  if (_hasSelection) {
    [self clearSelection];
  }

  NSString *characters = [event characters];
  NSString *sequence = nil;
  switch ([event keyCode]) {
  case 123:
    sequence = @"\033[D";
    break;
  case 124:
    sequence = @"\033[C";
    break;
  case 125:
    sequence = @"\033[B";
    break;
  case 126:
    sequence = @"\033[A";
    break;
  case 115:
    sequence = @"\033[H";
    break;
  case 119:
    sequence = @"\033[F";
    break;
  case 116:
    sequence = @"\033[5~";
    break;
  case 121:
    sequence = @"\033[6~";
    break;
  case 51:
    sequence = @"\177";
    break;
  case 117:
    sequence = @"\033[3~";
    break;
  default:
    break;
  }

  if (sequence != nil) {
    NSData *data = [sequence dataUsingEncoding:NSUTF8StringEncoding];
    [_session sendInput:data];
    return;
  }

  if ([characters length] == 0) {
    [super keyDown:event];
    return;
  }

  NSUInteger flags = [event modifierFlags];
  BOOL hasCtrl = (flags & NSControlKeyMask) != 0;
  BOOL hasCmd = (flags & NSCommandKeyMask) != 0;
  BOOL hasShift = (flags & NSShiftKeyMask) != 0;
  BOOL hasAlt = (flags & NSAlternateKeyMask) != 0;

  // Treat Cmd as Ctrl-equivalent for terminal control bytes. On GNUstep on Linux,
  // the physical Ctrl key is commonly mapped to NSCommandKeyMask; on macOS it maps
  // to NSControlKeyMask. Either way, bare modifier+letter (no Shift) means a
  // terminal control byte. Shift-modified variants are reserved for app shortcuts.
  if ((hasCtrl || hasCmd) && !hasShift) {
    unichar first = [characters characterAtIndex:0];
    if (first >= 0x01 && first <= 0x1f) {
      if (debugKeys) {
        fprintf(stderr, "[COT keyDown]   -> characters already control byte 0x%02x\n", (unsigned)first);
        fflush(stderr);
      }
    } else {
      NSString *base = [event charactersIgnoringModifiers];
      unichar effective = [base length] > 0 ? [base characterAtIndex:0] : first;
      unsigned char control = 0;
      BOOL translated = NO;
      if (effective >= 'a' && effective <= 'z') {
        control = (unsigned char)(effective - 'a' + 1);
        translated = YES;
      } else if (effective >= 'A' && effective <= 'Z') {
        control = (unsigned char)(effective - 'A' + 1);
        translated = YES;
      } else if (effective == ' ' || effective == '2' || effective == '@') {
        control = 0x00;
        translated = YES;
      } else if (effective == '[' || effective == '3') {
        control = 0x1b;
        translated = YES;
      } else if (effective == '\\' || effective == '4') {
        control = 0x1c;
        translated = YES;
      } else if (effective == ']' || effective == '5') {
        control = 0x1d;
        translated = YES;
      } else if (effective == '^' || effective == '6') {
        control = 0x1e;
        translated = YES;
      } else if (effective == '_' || effective == '7' || effective == '/' || effective == '?') {
        control = 0x1f;
        translated = YES;
      }
      if (translated) {
        if (hasAlt) {
          unsigned char esc = 0x1b;
          [_session sendInput:[NSData dataWithBytes:&esc length:1]];
        }
        [_session sendInput:[NSData dataWithBytes:&control length:1]];
        if (debugKeys) {
          fprintf(stderr, "[COT keyDown]   -> translated to control byte 0x%02x\n", control);
          fflush(stderr);
        }
        return;
      }
    }
  }

  if (hasAlt && !hasCmd && !hasCtrl && [characters length] > 0) {
    NSMutableData *data = [NSMutableData dataWithCapacity:1 + [characters length]];
    unsigned char esc = 0x1b;
    [data appendBytes:&esc length:1];
    [data appendData:[characters dataUsingEncoding:NSUTF8StringEncoding]];
    [_session sendInput:data];
    return;
  }

  NSData *data = [characters dataUsingEncoding:NSUTF8StringEncoding];
  [_session sendInput:data];
  if (debugKeys) {
    fprintf(stderr, "[COT keyDown]   -> sent %lu byte(s) as-is to PTY\n", (unsigned long)[data length]);
    fflush(stderr);
  }
}

- (void)mouseDown:(NSEvent *)event {
  [[self window] makeFirstResponder:self];
  BOOL shift = ([event modifierFlags] & NSShiftKeyMask) != 0;
  BOOL hadSelection = _hasSelection;
  _hasSelection = NO;
  if ([_session isMouseReportingEnabled] && !shift) {
    _selectingLocally = NO;
    _activeMouseButton = 0;
    if (hadSelection) {
      [self setNeedsDisplay:YES];
    }
    [self sendMouseReportForEvent:event button:0 pressed:YES];
    return;
  }
  _selectingLocally = YES;
  NSInteger row = 0;
  NSInteger column = 0;
  [self cellCoordinatesForEvent:event row:&row column:&column];
  _selectionAnchorRow = row;
  _selectionAnchorColumn = column;
  _selectionCurrentRow = row;
  _selectionCurrentColumn = column;
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
  if (_selectingLocally) {
    NSInteger row = 0;
    NSInteger column = 0;
    [self cellCoordinatesForEvent:event row:&row column:&column];
    _selectionCurrentRow = row;
    _selectionCurrentColumn = column;
    _hasSelection = (_selectionAnchorRow != _selectionCurrentRow ||
                     _selectionAnchorColumn != _selectionCurrentColumn);
    [self setNeedsDisplay:YES];
    return;
  }
  if (![_session isMouseButtonMotionReportingEnabled] && ![_session isMouseAnyMotionReportingEnabled]) {
    return;
  }
  int button = _activeMouseButton >= 0 ? _activeMouseButton : 0;
  [self sendMouseReportForEvent:event button:(button + 32) pressed:YES];
}

- (void)mouseUp:(NSEvent *)event {
  if (_selectingLocally) {
    _selectingLocally = NO;
    return;
  }
  if (![_session isMouseReportingEnabled]) {
    return;
  }
  int button = _activeMouseButton >= 0 ? _activeMouseButton : 0;
  [self sendMouseReportForEvent:event button:button pressed:NO];
  _activeMouseButton = -1;
}

- (void)cellCoordinatesForEvent:(NSEvent *)event row:(NSInteger *)outRow column:(NSInteger *)outColumn {
  COTTerminalTheme *theme = [[_session configuration] theme];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : MAX([@"M" sizeWithAttributes:_textAttributes].width, 1.0);
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : MAX([[theme font] ascender] - [[theme font] descender] + [theme lineSpacing], 1.0);
  NSEdgeInsets insets = [theme contentInsets];
  NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
  CGFloat x = point.x - insets.left;
  CGFloat yFromTop = NSMaxY([self bounds]) - insets.top - point.y;
  NSInteger column = (NSInteger)floor(x / cellWidth);
  NSInteger row = (NSInteger)floor(yFromTop / lineHeight);
  if (column < 0) column = 0;
  if (row < 0) row = 0;
  if (column > (NSInteger)[_session columns]) column = (NSInteger)[_session columns];
  if (row > (NSInteger)[_session rows] - 1) row = (NSInteger)[_session rows] - 1;
  if (outRow) *outRow = row;
  if (outColumn) *outColumn = column;
}

- (void)clearSelection {
  if (_hasSelection || _selectingLocally) {
    _hasSelection = NO;
    _selectingLocally = NO;
    [self setNeedsDisplay:YES];
  }
}

// Standard NSResponder action methods so menu items and key-equivalent
// dispatch (which targets @selector(copy:), @selector(paste:),
// @selector(selectAll:)) actually reach this view.
- (void)copy:(id)sender {
  (void)sender;
  [self copySelection];
}

- (void)paste:(id)sender {
  (void)sender;
  [self pasteFromClipboard];
}

- (void)selectAll:(id)sender {
  (void)sender;
  [self selectAll];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL action = [item action];
  if (action == @selector(copy:)) {
    return _hasSelection;
  }
  if (action == @selector(paste:) || action == @selector(selectAll:)) {
    return YES;
  }
  return YES;
}

- (void)selectAll {
  _selectionAnchorRow = 0;
  _selectionAnchorColumn = 0;
  _selectionCurrentRow = (NSInteger)[_session rows] - 1;
  _selectionCurrentColumn = (NSInteger)[_session columns];
  _hasSelection = YES;
  [self setNeedsDisplay:YES];
}

- (void)normalizedSelectionStartRow:(NSInteger *)startRow
                        startColumn:(NSInteger *)startColumn
                             endRow:(NSInteger *)endRow
                          endColumn:(NSInteger *)endColumn {
  NSInteger r0 = _selectionAnchorRow;
  NSInteger c0 = _selectionAnchorColumn;
  NSInteger r1 = _selectionCurrentRow;
  NSInteger c1 = _selectionCurrentColumn;
  BOOL swap = (r1 < r0) || (r1 == r0 && c1 < c0);
  if (swap) {
    if (startRow) *startRow = r1;
    if (startColumn) *startColumn = c1;
    if (endRow) *endRow = r0;
    if (endColumn) *endColumn = c0;
  } else {
    if (startRow) *startRow = r0;
    if (startColumn) *startColumn = c0;
    if (endRow) *endRow = r1;
    if (endColumn) *endColumn = c1;
  }
}

- (NSString *)selectedText {
  if (!_hasSelection) {
    return @"";
  }
  NSInteger startRow, startColumn, endRow, endColumn;
  [self normalizedSelectionStartRow:&startRow startColumn:&startColumn endRow:&endRow endColumn:&endColumn];
  NSArray *rows = [_session styledVisibleRows];
  NSMutableString *result = [NSMutableString string];
  for (NSInteger row = startRow; row <= endRow && row < (NSInteger)[rows count]; ++row) {
    NSArray *cells = [rows objectAtIndex:(NSUInteger)row];
    NSInteger firstCol = (row == startRow) ? startColumn : 0;
    NSInteger lastCol = (row == endRow) ? endColumn : (NSInteger)[cells count];
    NSMutableString *line = [NSMutableString string];
    NSInteger column = 0;
    for (NSDictionary *cell in cells) {
      NSInteger width = [[cell objectForKey:@"width"] integerValue];
      if (width < 1) width = 1;
      if (column >= firstCol && column < lastCol) {
        NSString *text = [cell objectForKey:@"text"];
        if (text != nil) {
          [line appendString:text];
        }
      }
      column += width;
      if (column >= lastCol) break;
    }
    NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (row != endRow) {
      [result appendString:trimmedLine];
      [result appendString:@"\n"];
    } else {
      [result appendString:[line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@""]]];
    }
  }
  return result;
}

- (void)copySelection {
  NSString *text = [self selectedText];
  if ([text length] == 0) {
    return;
  }
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
  [pasteboard setString:text forType:NSStringPboardType];
}

- (void)pasteFromClipboard {
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  NSString *text = [pasteboard stringForType:NSStringPboardType];
  if ([text length] == 0) {
    return;
  }
  NSMutableString *normalized = [NSMutableString stringWithString:text];
  [normalized replaceOccurrencesOfString:@"\r\n" withString:@"\r" options:0 range:NSMakeRange(0, [normalized length])];
  [normalized replaceOccurrencesOfString:@"\n" withString:@"\r" options:0 range:NSMakeRange(0, [normalized length])];
  if ([_session isBracketedPasteEnabled]) {
    [_session sendInput:[@"\033[200~" dataUsingEncoding:NSUTF8StringEncoding]];
    [_session sendInput:[normalized dataUsingEncoding:NSUTF8StringEncoding]];
    [_session sendInput:[@"\033[201~" dataUsingEncoding:NSUTF8StringEncoding]];
  } else {
    [_session sendInput:[normalized dataUsingEncoding:NSUTF8StringEncoding]];
  }
}

- (void)scrollWheel:(NSEvent *)event {
  if ([_session isMouseReportingEnabled]) {
    int button = [event deltaY] > 0 ? 64 : 65;
    [self sendMouseReportForEvent:event button:button pressed:YES];
    return;
  }
  CGFloat dy = [event deltaY];
  if (dy == 0.0) {
    return;
  }
  NSInteger lines = (NSInteger)(dy > 0 ? ceil(dy * 3.0) : floor(dy * 3.0));
  if (lines == 0) {
    lines = dy > 0 ? 1 : -1;
  }
  [_session adjustViewportOffset:lines];
}

- (void)sendMouseReportForEvent:(NSEvent *)event button:(int)button pressed:(BOOL)pressed {
  if (![[_session visibleLines] count]) {
    return;
  }
  COTTerminalTheme *theme = [[_session configuration] theme];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : MAX([@"M" sizeWithAttributes:_textAttributes].width, 1.0);
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : MAX([[theme font] ascender] - [[theme font] descender] + [theme lineSpacing], 1.0);
  NSEdgeInsets insets = [theme contentInsets];
  NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
  int column = MAX(1, MIN((int)[_session columns], (int)((point.x - insets.left) / cellWidth) + 1));
  int row = MAX(1, MIN((int)[_session rows], (int)((NSMaxY([self bounds]) - insets.top - point.y) / lineHeight) + 1));
  NSString *report = [NSString stringWithFormat:@"\033[<%d;%d;%d%c", button, column, row, pressed ? 'M' : 'm'];
  NSData *data = [report dataUsingEncoding:NSUTF8StringEncoding];
  [_session sendInput:data];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self updateTerminalSizeFromBounds];
}

- (void)viewFrameDidChange:(NSNotification *)notification {
  (void)notification;
  [self updateTerminalSizeFromBounds];
  [self setNeedsDisplay:YES];
}

- (BOOL)handleClipboardShortcut:(NSEvent *)event {
  NSUInteger flags = [event modifierFlags];
  BOOL hasCmd = (flags & NSCommandKeyMask) != 0;
  BOOL hasShift = (flags & NSShiftKeyMask) != 0;
  // Require Cmd+Shift so we never collide with terminal-control Ctrl+letter
  // (on GNUstep the physical Ctrl key often delivers NSCommandKeyMask, so bare
  // Cmd+letter must remain available as a terminal control byte).
  if (!hasCmd || !hasShift) {
    return NO;
  }
  NSString *chars = [[event charactersIgnoringModifiers] lowercaseString];
  if ([chars isEqualToString:@"c"]) {
    [self copySelection];
    return YES;
  }
  if ([chars isEqualToString:@"v"]) {
    [self pasteFromClipboard];
    return YES;
  }
  if ([chars isEqualToString:@"a"]) {
    [self selectAll];
    return YES;
  }
  return NO;
}

- (BOOL)handleScrollbackShortcut:(NSEvent *)event {
  NSUInteger flags = [event modifierFlags];
  BOOL hasCmd = (flags & NSCommandKeyMask) != 0;
  BOOL hasShift = (flags & NSShiftKeyMask) != 0;
  if (!hasCmd && !hasShift) {
    return NO;
  }
  NSInteger pageStep = MAX((NSInteger)1, (NSInteger)([_session rows] / 2));
  unsigned short keyCode = [event keyCode];
  if (hasCmd) {
    switch (keyCode) {
    case 126:
      [_session adjustViewportOffset:pageStep];
      return YES;
    case 125:
      [_session adjustViewportOffset:-pageStep];
      return YES;
    case 115:
      [_session setViewportOffset:[_session maxViewportOffset]];
      return YES;
    case 119:
      [_session scrollToBottom];
      return YES;
    default:
      break;
    }
  }
  if (hasShift) {
    if (keyCode == 116) {
      [_session adjustViewportOffset:pageStep];
      return YES;
    }
    if (keyCode == 121) {
      [_session adjustViewportOffset:-pageStep];
      return YES;
    }
  }
  return NO;
}

- (BOOL)handleZoomShortcut:(NSEvent *)event {
  NSUInteger flags = [event modifierFlags];
  BOOL ctrl = (flags & NSControlKeyMask) != 0;
  BOOL cmd = (flags & NSCommandKeyMask) != 0;
  if (!ctrl && !cmd) {
    return NO;
  }

  NSString *characters = [event characters];
  NSString *charactersIgnoringModifiers = [event charactersIgnoringModifiers];
  unichar character = [characters length] > 0 ? [characters characterAtIndex:0] : 0;
  unichar baseCharacter = [charactersIgnoringModifiers length] > 0 ? [charactersIgnoringModifiers characterAtIndex:0] : 0;
  unsigned short keyCode = [event keyCode];

  if (character == '+' || baseCharacter == '+' || character == '=' || baseCharacter == '=' ||
      keyCode == 24 || keyCode == 69) {
    [self zoomIn];
    return YES;
  }
  if (character == '-' || baseCharacter == '-' || keyCode == 27 || keyCode == 78) {
    [self zoomOut];
    return YES;
  }
  if (character == '0' || baseCharacter == '0' || keyCode == 29 || keyCode == 82) {
    [self resetZoom];
    return YES;
  }

  return NO;
}

- (void)rebuildTextAttributes {
  [_textAttributes release];
  COTTerminalTheme *theme = [[_session configuration] theme];
  _textAttributes = [[NSDictionary alloc] initWithObjectsAndKeys:
    [theme font], NSFontAttributeName,
    [theme foregroundColor], NSForegroundColorAttributeName,
    nil];
  NSFont *font = [theme font];
  _cellWidth = MAX([@"M" sizeWithAttributes:_textAttributes].width, 1.0);
  _lineHeight = MAX([font ascender] - [font descender] + [theme lineSpacing], 1.0);
}

- (void)updateTerminalSizeFromBounds {
  if (_session == nil) {
    return;
  }
  COTTerminalTheme *theme = [[_session configuration] theme];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : MAX([@"M" sizeWithAttributes:_textAttributes].width, 1.0);
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : MAX([[theme font] ascender] - [[theme font] descender] + [theme lineSpacing], 1.0);
  NSEdgeInsets insets = [theme contentInsets];
  NSRect bounds = [self bounds];
  CGFloat usableWidth = MAX(bounds.size.width - insets.left - insets.right, cellWidth);
  CGFloat usableHeight = MAX(bounds.size.height - insets.top - insets.bottom, lineHeight);
  NSUInteger columns = MAX((NSUInteger)floor(usableWidth / cellWidth), 1);
  NSUInteger rows = MAX((NSUInteger)floor(usableHeight / lineHeight), 1);
  if (columns != [_session columns] || rows != [_session rows]) {
    [_session resizeToColumns:columns rows:rows];
  }
}

- (void)setZoomFontSize:(CGFloat)fontSize {
  COTTerminalTheme *theme = [[_session configuration] theme];
  CGFloat clamped = MIN(MAX(fontSize, 8.0), 32.0);
  if (fabs([theme fontSize] - clamped) < 0.01) {
    return;
  }
  [theme setFontSize:clamped];
  [self rebuildTextAttributes];
  [self updateTerminalSizeFromBounds];
  [self setNeedsDisplay:YES];
}

- (void)zoomIn {
  COTTerminalTheme *theme = [[_session configuration] theme];
  [self setZoomFontSize:[theme fontSize] + 1.0];
}

- (void)zoomOut {
  COTTerminalTheme *theme = [[_session configuration] theme];
  [self setZoomFontSize:[theme fontSize] - 1.0];
}

- (void)resetZoom {
  [self setZoomFontSize:_baseFontSize];
}

- (void)terminalSessionDidUpdateScreen:(COTTerminalSession *)session {
  (void)session;
  if (_lineHeight <= 0 || _cellWidth <= 0 || [_session viewportOffset] > 0) {
    [self setNeedsDisplay:YES];
    return;
  }
  NSArray<NSNumber *> *dirty = [_session takeDirtyRows];
  if ([dirty count] == 0) {
    return;
  }
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSEdgeInsets insets = [theme contentInsets];
  CGFloat top = NSMaxY([self bounds]) - insets.top;
  CGFloat width = NSWidth([self bounds]);
  for (NSNumber *index in dirty) {
    NSInteger row = [index integerValue];
    NSRect rect = NSMakeRect(0, top - (row + 1) * _lineHeight, width, _lineHeight);
    [self setNeedsDisplayInRect:rect];
  }
  [self setNeedsDisplayInRect:NSMakeRect(0, top - ([_session cursorRow] + 1) * _lineHeight, width, _lineHeight)];
}

- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)status {
  (void)session;
  (void)status;
  COTTerminalExitBehavior behavior = [[_session configuration] exitBehavior];
  if (behavior == COTTerminalExitBehaviorCloseOwningWindow) {
    [[self window] close];
  } else if (behavior == COTTerminalExitBehaviorTerminateApplication) {
    [NSApp terminate:nil];
  }
}

@synthesize session = _session;

@end
