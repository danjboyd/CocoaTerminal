// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalTheme.h>
#import <CocoaTerminal/COTTerminalView.h>

#import "COTAppKitCompat.h"
#import "COTTerminalSessionInternal.h"

#include <math.h>

#if defined(_WIN32)
#include <shellapi.h>  // ShellExecuteW, for links
#include <imm.h>  // placing the input method's composition window
#endif

#include <unordered_map>

#include "COTCairoCells.h"
#include "COTGLRenderer.h"

static NSString *const COTTerminalViewErrorDomain = @"COTTerminalViewErrorDomain";
NSString *const COTTerminalViewDidExitNotification = @"COTTerminalViewDidExitNotification";
NSString *const COTTerminalViewDidUpdateScreenNotification = @"COTTerminalViewDidUpdateScreenNotification";
NSString *const COTTerminalExitStatusUserInfoKey = @"status";
static NSUInteger const COTTerminalMaximumColumns = 1000;
static NSUInteger const COTTerminalMaximumRows = 1000;

static NSTimeInterval COTTerminalRepaintInterval(void) {
  static NSTimeInterval interval = 0.0;
  if (interval == 0.0) {
    double maxFPS = 30.0;
    const char *override_ = getenv("COCOATERMINAL_MAX_FPS");
    if (override_ != NULL) {
      double parsed = atof(override_);
      if (parsed >= 5.0 && parsed <= 120.0) {
        maxFPS = parsed;
      }
    }
    interval = 1.0 / maxFPS;
  }
  return interval;
}

static NSString *COTSequenceForFunctionKey(unichar key) {
  switch (key) {
  case NSUpArrowFunctionKey:
    return @"\033[A";
  case NSDownArrowFunctionKey:
    return @"\033[B";
  case NSRightArrowFunctionKey:
    return @"\033[C";
  case NSLeftArrowFunctionKey:
    return @"\033[D";
  case NSHomeFunctionKey:
    return @"\033[H";
  case NSEndFunctionKey:
    return @"\033[F";
  case NSPageUpFunctionKey:
    return @"\033[5~";
  case NSPageDownFunctionKey:
    return @"\033[6~";
  case NSInsertFunctionKey:
    return @"\033[2~";
  case NSDeleteFunctionKey:
  case NSDeleteCharFunctionKey:
    return @"\033[3~";
  // xterm's function keys (what TERM=xterm-256color promises).
  case NSF1FunctionKey: return @"\033OP";
  case NSF2FunctionKey: return @"\033OQ";
  case NSF3FunctionKey: return @"\033OR";
  case NSF4FunctionKey: return @"\033OS";
  case NSF5FunctionKey: return @"\033[15~";
  case NSF6FunctionKey: return @"\033[17~";
  case NSF7FunctionKey: return @"\033[18~";
  case NSF8FunctionKey: return @"\033[19~";
  case NSF9FunctionKey: return @"\033[20~";
  case NSF10FunctionKey: return @"\033[21~";
  case NSF11FunctionKey: return @"\033[23~";
  case NSF12FunctionKey: return @"\033[24~";
  default:
    return nil;
  }
}

// A cell's text as GNUstep can draw it. Composed (NFC): its simple layout gives a combining mark an advance of its own,
// so e + U+0301 drew as "e´" and pushed the rest of the line a cell right. Without variation selectors (U+FE0E, U+FE0F),
// which draw as "?": they choose the presentation, which -fallbackFontFor: honours.
// (By character: GNUstep's -rangeOfString: raises "Invalid location" when the string sought is a selector.)
static BOOL COTContainsCharacter(NSString *text, unichar c) {
  NSUInteger length = [text length];
  for (NSUInteger i = 0; i < length; ++i) {
    if ([text characterAtIndex:i] == c) return YES;
  }
  return NO;
}

static NSString *COTDrawableCellText(NSString *text) {
  NSString *composed = [text precomposedStringWithCanonicalMapping] ?: text;
  if (!COTContainsCharacter(composed, 0xFE0E) && !COTContainsCharacter(composed, 0xFE0F)) {
    return composed;
  }
  NSMutableString *stripped = [NSMutableString stringWithCapacity:[composed length]];
  NSUInteger length = [composed length];
  for (NSUInteger i = 0; i < length; ++i) {
    unichar c = [composed characterAtIndex:i];
    if (c != 0xFE0E && c != 0xFE0F) [stripped appendFormat:@"%C", c];
  }
  return stripped;
}

// Characters Unicode draws as emoji by default (Emoji_Presentation=Yes) in the BMP. Everything from U+1F000 on that
// reaches the fallback is treated as emoji too. Symbols outside this list (✳ ✶ ●, Claude Code's spinner) stay text.
static BOOL COTIsDefaultEmoji(UTF32Char c) {
  static const UTF32Char ranges[][2] = {
    {0x231A, 0x231B}, {0x23E9, 0x23EC}, {0x23F0, 0x23F0}, {0x23F3, 0x23F3}, {0x25FD, 0x25FE}, {0x2614, 0x2615},
    {0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1}, {0x26AA, 0x26AB}, {0x26BD, 0x26BE},
    {0x26C4, 0x26C5}, {0x26CE, 0x26CE}, {0x26D4, 0x26D4}, {0x26EA, 0x26EA}, {0x26F2, 0x26F3}, {0x26F5, 0x26F5},
    {0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B}, {0x2728, 0x2728}, {0x274C, 0x274C},
    {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2795, 0x2797}, {0x27B0, 0x27B0}, {0x27BF, 0x27BF},
    {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55},
  };
  if (c >= 0x1F000) return YES;
  for (const auto &range : ranges) {
    if (c >= range[0] && c <= range[1]) return YES;
  }
  return NO;
}

// Shift+Tab, however the backend reports it: Tab with Shift, or the back-tab character as the key itself (not as the
// control character Ctrl+Y also makes, whose key is "y").
// Text typed with AltGr: Windows reports AltGr as Ctrl+Alt, so a European layout's @, €, { or ä arrives with both,
// and must be typed, not turned into a control byte. The layout made a printable character that isn't the key's
// own (unmodified) one.
static BOOL COTIsAltGrText(NSEvent *event) {
  NSUInteger flags = [event modifierFlags];
  if (!(flags & NSAlternateKeyMask) || !(flags & (NSControlKeyMask | NSCommandKeyMask))) {
    return NO;
  }
  NSString *characters = [event characters];
  NSString *base = [event charactersIgnoringModifiers];
  if ([characters length] == 0) {
    return NO;
  }
  unichar first = [characters characterAtIndex:0];
  if (first < 0x20 || first == 0x7f || (first >= 0xF700 && first <= 0xF8FF)) {
    return NO;  // a control character, or a function key
  }
  return ![characters isEqualToString:base] && ![[characters lowercaseString] isEqualToString:[base lowercaseString]];
}

static BOOL COTIsBackTab(NSEvent *event) {
  NSString *base = [event charactersIgnoringModifiers];
  unichar key = [base length] > 0 ? [base characterAtIndex:0] : 0;
  if (key == NSBackTabCharacter) {
    return YES;
  }
  return key == NSTabCharacter && ([event modifierFlags] & NSShiftKeyMask) != 0;
}

static NSColor *COTColorFromTerminalColor(const cot::TerminalColor &color, COTTerminalTheme *theme, BOOL foreground) {
  switch (color.kind) {
  case cot::TerminalColor::Kind::Palette: {
    NSArray *colors = [theme ansiColors];
    if (color.index >= 0 && color.index < (int)[colors count]) {
      return [colors objectAtIndex:(NSUInteger)color.index];
    }
    // A 16-colour palette still gives programs the standard 256-colour range.
    NSColor *standard = color.index >= 16 ? [COTTerminalTheme xtermColorAtIndex:(NSUInteger)color.index] : nil;
    if (standard != nil) {
      return standard;
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
  // The theme font's faces for SGR 1 (bold), 3 (italic) and both, indexed by (bold | italic << 1); index 0 is the
  // regular font. A face the family hasn't got, or one with a different advance (it would break the grid), is the
  // regular font.
  NSFont *_styledFonts[4];
  NSMutableDictionary *_fallbackFonts;  // by character: a covering font sized to the cell, or NSNull (see -fallbackFontFor:)
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
  BOOL _terminalSizeUpdateScheduled;
  BOOL _screenUpdateScheduled;
  BOOL _pendingFullRedraw;
  NSMutableIndexSet *_pendingDirtyRows;
  // The row the cursor was last painted on (NSNotFound: none). A cursor that leaves a row whose text didn't change
  // must still repaint that row, or its old block stays on screen.
  NSUInteger _paintedCursorRow;
  BOOL _perfLoggingEnabled;
  NSTimeInterval _perfLastLogTime;
  NSUInteger _perfScreenUpdates;
  NSUInteger _perfDrawCalls;
  NSUInteger _perfDirtyRows;
  NSUInteger _perfFullRedraws;
  // The OpenGL renderer, the font it was made for, the context it lives in (NULL: its own, drawing into _glImage),
  // the image, and the NSOpenGLView it draws into when it draws straight to the window.
  cot::GLRenderer *_glRenderer;
  NSString *_glFontKey;
  void *_glRendererContext;
  NSBitmapImageRep *_glImage;
  NSOpenGLView *_glSurface;
  BOOL _glUnavailable;
  // Search: the find bar (nil while hidden), the text last searched for, and where its match was (a line as
  // -[COTTerminalSession findText:...] numbers them, NSNotFound before the first match).
  NSTextField *_findField;
  NSString *_findText;
  NSUInteger _findLine;
  NSUInteger _findColumn;
  BOOL _findCaseSensitive;
}
- (void)drawGLSurface:(NSOpenGLView *)surface;
@end

// The OpenGL renderer drawing straight into the window: an NSOpenGLView covering the terminal view, which takes no
// events (they go to the terminal view) and asks the terminal view to draw it.
@interface COTGLSurfaceView : NSOpenGLView {
  COTTerminalView *_terminal;  // not retained: the terminal view owns this
}
- (instancetype)initWithFrame:(NSRect)frame pixelFormat:(NSOpenGLPixelFormat *)format terminal:(COTTerminalView *)terminal;
@end

@implementation COTGLSurfaceView
- (instancetype)initWithFrame:(NSRect)frame pixelFormat:(NSOpenGLPixelFormat *)format terminal:(COTTerminalView *)terminal {
  self = [super initWithFrame:frame pixelFormat:format];
  if (self) _terminal = terminal;
  return self;
}
- (NSView *)hitTest:(NSPoint)point {
  (void)point;
  return nil;
}
- (BOOL)acceptsFirstResponder {
  return NO;
}
- (BOOL)isOpaque {
  return YES;
}
- (void)drawRect:(NSRect)rect {
  (void)rect;
  [_terminal drawGLSurface:self];
}
@end

// Whether the OpenGL renderer can draw straight into the window: GNUstep's NSOpenGLView is a native child window,
// usable only when GNUstep hides, moves and clips it with the view (danjboyd/libs-gui and libs-back, branch
// glview-visibility; until then the view draws an image). COCOATERMINAL_GL_PRESENT=window or =image overrides.
static BOOL COTGLSurfaceUsable(void) {
  static int usable = -1;
  if (usable < 0) {
    const char *choice = getenv("COCOATERMINAL_GL_PRESENT");
    if (choice != NULL && strcmp(choice, "window") == 0) {
      usable = 1;
    } else if (choice != NULL && strcmp(choice, "image") == 0) {
      usable = 0;
    } else {
#if defined(_WIN32)
      usable = [NSOpenGLView instancesRespondToSelector:@selector(_setNeedsDrawableUpdate)] ? 1 : 0;
#else
      usable = 0;  // needs a GLX context for the renderer (COTGLContextEGL.cpp)
#endif
    }
  }
  return usable == 1;
}

// The key as macOS numbers it. On macOS that's the event's keyCode. GNUstep's keyCode is the X11 keycode, which collides
// with these (X 51 is backslash/bar, so "|" sent Backspace; 24/27/29 are q/r/y, so Ctrl+Q/R/Y zoomed), so there the
// function-key character stands in, and any other key has no code.
static unsigned short COTMacKeyCode(NSEvent *event) {
#if defined(__APPLE__)
  return [event keyCode];
#else
  NSString *base = [event charactersIgnoringModifiers];
  unichar c = [base length] > 0 ? [base characterAtIndex:0] : 0;
  switch (c) {
  case NSLeftArrowFunctionKey: return 123;
  case NSRightArrowFunctionKey: return 124;
  case NSDownArrowFunctionKey: return 125;
  case NSUpArrowFunctionKey: return 126;
  case NSHomeFunctionKey: return 115;
  case NSEndFunctionKey: return 119;
  case NSPageUpFunctionKey: return 116;
  case NSPageDownFunctionKey: return 121;
  case NSDeleteFunctionKey: return 117;
  default: return 0xFFFF;
  }
#endif
}

#if !defined(__APPLE__)
#if defined(_WIN32)
// GNUstep's Foundation brings in the Win32 loader. Its Windows backend (Cairo) links libfontconfig-1.dll, so that's
// normally loaded already.
#define RTLD_LAZY 0
#define RTLD_NOLOAD 1
static void *dlopen(const char *name, int flags) {
  (void)name;
  HMODULE module = GetModuleHandleA("libfontconfig-1.dll");
  if (module == NULL && !(flags & RTLD_NOLOAD)) module = LoadLibraryA("libfontconfig-1.dll");
  return (void *)module;
}
static void *dlsym(void *module, const char *name) { return (void *)GetProcAddress((HMODULE)module, name); }
#else
#include <dlfcn.h>
#endif
#include <fontconfig/fontconfig.h>

// A font for a character the terminal's font hasn't got (Claude Code's spinner, ✢ ✳ ✶ ✻ ✽ ● ⏺): fontconfig's choice,
// as Alacritty's, by PostScript name (the names GNUstep's fonts go by). fontconfig is looked up at run time (GNUstep's
// backend has it loaded), so nothing new is linked; without it, nil, and the character draws as before.
// With color, a colour font (an emoji font) rather than one like the terminal's.
static NSString *COTFallbackFontName(UTF32Char character, NSString *family, BOOL color) {
  static void *library;
  static BOOL tried;
  if (!tried) {
    tried = YES;
    library = dlopen("libfontconfig.so.1", RTLD_LAZY | RTLD_NOLOAD);
    if (!library) library = dlopen("libfontconfig.so.1", RTLD_LAZY);
  }
  if (!library) return nil;
#define COT_FC(name) __typeof__(&name) p##name = (__typeof__(&name))dlsym(library, #name)
  COT_FC(FcPatternCreate); COT_FC(FcPatternDestroy); COT_FC(FcPatternAddString); COT_FC(FcPatternAddCharSet);
  COT_FC(FcCharSetCreate); COT_FC(FcCharSetDestroy); COT_FC(FcCharSetAddChar); COT_FC(FcCharSetHasChar);
  COT_FC(FcConfigSubstitute); COT_FC(FcDefaultSubstitute); COT_FC(FcFontMatch); COT_FC(FcPatternGetString);
  COT_FC(FcPatternGetCharSet); COT_FC(FcPatternAddBool);
#undef COT_FC
  if (!pFcPatternCreate || !pFcPatternDestroy || !pFcPatternAddString || !pFcPatternAddCharSet || !pFcCharSetCreate ||
      !pFcCharSetDestroy || !pFcCharSetAddChar || !pFcCharSetHasChar || !pFcConfigSubstitute || !pFcDefaultSubstitute ||
      !pFcFontMatch || !pFcPatternGetString || !pFcPatternGetCharSet || !pFcPatternAddBool)
    return nil;
  FcPattern *pattern = pFcPatternCreate();
  if (color) {
#ifdef FC_COLOR
    pFcPatternAddBool(pattern, FC_COLOR, FcTrue);
#else
    pFcPatternAddBool(pattern, "color", FcTrue);
#endif
  } else if (family.length) {
    pFcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)[family UTF8String]);
  }
  FcCharSet *wanted = pFcCharSetCreate();
  pFcCharSetAddChar(wanted, character);
  pFcPatternAddCharSet(pattern, FC_CHARSET, wanted);
  pFcConfigSubstitute(NULL, pattern, FcMatchPattern);
  pFcDefaultSubstitute(pattern);
  FcResult result;
  FcPattern *match = pFcFontMatch(NULL, pattern, &result);
  NSString *name = nil;
  FcCharSet *has = NULL;
  FcChar8 *postscript = NULL;
  if (match && pFcPatternGetCharSet(match, FC_CHARSET, 0, &has) == FcResultMatch && pFcCharSetHasChar(has, character) &&
      pFcPatternGetString(match, FC_POSTSCRIPT_NAME, 0, &postscript) == FcResultMatch && postscript)
    name = [NSString stringWithUTF8String:(const char *)postscript];
  if (match) pFcPatternDestroy(match);
  pFcPatternDestroy(pattern);
  pFcCharSetDestroy(wanted);
  return name;
}
#endif

@implementation COTTerminalView

- (void)setFrame:(NSRect)frameRect {
  NSRect frame = frameRect;
  frame.origin.x = isfinite(frame.origin.x) ? frame.origin.x : 0.0;
  frame.origin.y = isfinite(frame.origin.y) ? frame.origin.y : 0.0;
  frame.size.width = isfinite(frame.size.width) ? MAX(1.0, frame.size.width) : 1.0;
  frame.size.height = isfinite(frame.size.height) ? MAX(1.0, frame.size.height) : 1.0;
  [super setFrame:frame];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  return [self initWithFrame:frameRect configuration:[COTTerminalConfiguration defaultConfiguration]];
}

- (instancetype)initWithFrame:(NSRect)frameRect configuration:(COTTerminalConfiguration *)configuration {
  self = [super initWithFrame:frameRect];
  if (self) {
    _session = [[COTTerminalSession alloc] initWithConfiguration:configuration];
    if (_session == nil) { [self release]; return nil; }
    [_session setDelegate:self];
    _baseFontSize = [[configuration theme] fontSize];
    _activeMouseButton = -1;
    _findLine = NSNotFound;
    _pendingDirtyRows = [[NSMutableIndexSet alloc] init];
    _paintedCursorRow = NSNotFound;
    _perfLoggingEnabled = getenv("COCOATERMINAL_PERF_LOG") != NULL;
    _perfLastLogTime = [NSDate timeIntervalSinceReferenceDate];
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
    _baseFontSize = [[[_session configuration] theme] fontSize];
    _activeMouseButton = -1;
    _findLine = NSNotFound;
    _pendingDirtyRows = [[NSMutableIndexSet alloc] init];
    _paintedCursorRow = NSNotFound;
    _perfLoggingEnabled = getenv("COCOATERMINAL_PERF_LOG") != NULL;
    _perfLastLogTime = [NSDate timeIntervalSinceReferenceDate];
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
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performPendingTerminalSizeUpdate) object:nil];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performPendingScreenUpdate) object:nil];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateInputMethodPosition) object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_session setDelegate:nil];
  [_session release];
  [_pendingDirtyRows release];
  [_textAttributes release];
  for (int i = 0; i < 4; ++i) {
    [_styledFonts[i] release];
  }
  [_fallbackFonts release];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(attachGLSurface) object:nil];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(detachGLSurface) object:nil];
  if (_glSurface != nil && _glRendererContext != NULL && [[_glSurface openGLContext] view] == _glSurface) {
    [[_glSurface openGLContext] makeCurrentContext];  // so the renderer can delete its objects in it
  }
  delete _glRenderer;
  [_glSurface removeFromSuperview];
  [_glSurface release];
  [_glFontKey release];
  [_glImage release];
  [_findField setDelegate:nil];
  [_findField setTarget:nil];
  [_findField release];
  [_findText release];
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

  // Key equivalents go to every view in the window, focused or not. Only the focused terminal may take them: a text
  // field beside a terminal (an embedder's chat box) keeps its Ctrl-V, and in a split only the focused pane pastes.
  if ([[self window] firstResponder] != self) {
    return [super performKeyEquivalent:event];
  }

  if ([self sendTerminalControlBytesForEvent:event debug:debugKeys]) {
    return YES;
  }

  // Clipboard shortcuts wired without a menubar (Alacritty-style). Require
  // Cmd+Shift so we never collide with terminal-control Ctrl+letter byte
  // translation in keyDown:.
  NSUInteger flags = [event modifierFlags];
  if ((flags & NSEventModifierFlagCommand) && (flags & NSEventModifierFlagShift)) {
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
    if ([base isEqualToString:@"f"]) {
      [self showFindBar];
      return YES;
    }
  }

  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  [self setNeedsDisplay:YES];
  [self performSelector:@selector(updateInputMethodPosition) withObject:nil afterDelay:0];  // once it has the focus
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

  // The screen updates at most 30 times a second: output that arrived since the last update (or whose notice is still
  // on its way to the main thread) hasn't marked the view dirty yet, so -displayIfNeeded would draw nothing new and the
  // capture (GNUstep reads the window's backing store) would predate it. Apply the update now; with no dirty rows
  // recorded it redraws the whole view.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performPendingScreenUpdate) object:nil];
  [self performPendingScreenUpdate];
  [self displayIfNeeded];
  // Drawn straight into the window, the frame isn't in anything GNUstep can read back: render it once more off screen,
  // in the surface's context, and read that.
  if (_glSurface != nil && _glRenderer != NULL && _glRendererContext != NULL &&
      [[_glSurface openGLContext] view] == _glSurface) {
    [self performPendingScreenUpdate];
    [[_glSurface openGLContext] makeCurrentContext];
    cot::GLFrame frame;
    std::string message;
    if ([self buildGLFrame:&frame size:[_glSurface bounds].size] &&
        _glRenderer->render(frame, [[self glImageForFrame:frame] bitmapData], &message)) {
      NSData *data = [_glImage representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
      if ([data length] > 0) {
        return data;
      }
    }
  }
#if defined(_WIN32)
  // GNUstep's Win32 Cairo backend draws no text into an off-screen cache, so read back what the window shows.
  if ([self window] != nil && [[self window] isVisible] && [self canDraw]) {
    // The screen updates at most 30 times a second; draw the latest now, or the capture can predate it.
    [self performPendingScreenUpdate];
    [self display];
    [self lockFocus];
    NSBitmapImageRep *shown = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:bounds] autorelease];
    [self unlockFocus];
    NSData *shownData = [shown representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
    if ([shownData length] > 0) {
      return shownData;
    }
  }
#endif
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

// 0xRRGGBB for a colour, with the theme's palette resolved.
static std::uint32_t COTRGB(NSColor *color) {
  NSColor *rgb = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  if (rgb == nil) return 0;
  return ((std::uint32_t)lround([rgb redComponent] * 255) << 16) | ((std::uint32_t)lround([rgb greenComponent] * 255) << 8) |
         (std::uint32_t)lround([rgb blueComponent] * 255);
}

// Whether to draw with OpenGL: the configuration's renderer, unless COCOATERMINAL_RENDERER says otherwise ("gl" or
// "opengl", "cairo", "auto"). Automatic means OpenGL only where it draws straight into the window (see
// COTTerminalRenderer): through an image it's slower than Cairo on plain text (T14, Intel iris: 5.7 ms a frame
// against 2.5; colour-heavy screens 5.7 against 120).
- (BOOL)wantsOpenGL {
  const char *choice = getenv("COCOATERMINAL_RENDERER");
  COTTerminalRenderer renderer = [[_session configuration] renderer];
  if (choice != NULL && (strcmp(choice, "gl") == 0 || strcmp(choice, "opengl") == 0)) renderer = COTTerminalRendererOpenGL;
  if (choice != NULL && strcmp(choice, "cairo") == 0) renderer = COTTerminalRendererCairo;
  if (choice != NULL && (strcmp(choice, "auto") == 0 || strcmp(choice, "automatic") == 0)) {
    renderer = COTTerminalRendererAutomatic;
  }
  if (renderer == COTTerminalRendererAutomatic) {
#if defined(COCOATERMINAL_GL_RENDERER)
    return COTGLSurfaceUsable() && [[[_session configuration] theme] opacity] >= 1.0;
#else
    return NO;
#endif
  }
  return renderer == COTTerminalRendererOpenGL;
}

// The renderer for the theme's font, living in the given OpenGL context (an NSOpenGLView's, current now), or in its
// own when context is NULL. NO, with the reason on stderr, if it can't start: drawing then falls back to Cairo.
- (BOOL)prepareGLRendererInContext:(void *)context {
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSFont *font = [theme font];
  BOOL opaque = [theme opacity] >= 1.0;
  // ClearType-style (LCD) glyphs by default only on Windows, which knows the screen's subpixel order and draws its own
  // text that way. Elsewhere Cairo draws grayscale, and the order is often unknown (Xvfb, Wayland, rotated screens), so
  // LCD glyphs would show colour fringes: grayscale unless COCOATERMINAL_GL_ANTIALIAS=cleartype (or lcd) asks for it.
  const char *antialias = getenv("COCOATERMINAL_GL_ANTIALIAS");
#if defined(_WIN32)
  BOOL wantClearType = !(antialias != NULL && strcmp(antialias, "grayscale") == 0);
#else
  BOOL wantClearType = antialias != NULL && (strcmp(antialias, "cleartype") == 0 || strcmp(antialias, "lcd") == 0);
#endif
  BOOL clearType = opaque && wantClearType;
  NSString *fontKey = [NSString stringWithFormat:@"%@|%.2f|%d", [theme fontFamily], [font pointSize], clearType];
  if (_glRenderer != NULL && [fontKey isEqualToString:_glFontKey] && _glRendererContext == context) {
    return YES;
  }
  // A renderer made in a context that has gone (the view's, replaced when it re-attached) finds it isn't current
  // and leaves its objects to it.
  delete _glRenderer;
  _glRenderer = NULL;
  _glRendererContext = NULL;
  std::string error;
  NSString *family = [font familyName] ?: [theme fontFamily];
  std::unique_ptr<cot::GLRenderer> renderer = cot::GLRenderer::create(
      [family UTF8String], (float)[font pointSize],
      clearType ? cot::GLRenderer::Antialiasing::ClearType : cot::GLRenderer::Antialiasing::Grayscale, &error,
      context != NULL ? cot::GLRenderer::Context::Current : cot::GLRenderer::Context::Own);
  if (!renderer) {
    fprintf(stderr, "[CocoaTerminal] OpenGL renderer unavailable, drawing with Cairo: %s\n", error.c_str());
    _glUnavailable = YES;
    return NO;
  }
  _glRenderer = renderer.release();
  _glRendererContext = context;
  [_glFontKey release];
  _glFontKey = [fontKey copy];
  if (_perfLoggingEnabled) fprintf(stderr, "[CocoaTerminal] renderer: %s\n", _glRenderer->description().c_str());
  return YES;
}

// Whether to draw straight into the window through an NSOpenGLView: OpenGL wanted and working, GNUstep able to keep
// the view's child window with it, and an opaque theme (a child window can't show what's behind the window).
// Not while the find bar shows: the surface's native child window would cover it.
- (BOOL)wantsGLSurface {
  return !_glUnavailable && [self wantsOpenGL] && COTGLSurfaceUsable() && [self window] != nil &&
         [[[_session configuration] theme] opacity] >= 1.0 && _findField == nil;
}

- (void)attachGLSurface {
  if (_glSurface != nil || ![self wantsGLSurface]) {
    return;
  }
  NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFAWindow, NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize,
                                               (NSOpenGLPixelFormatAttribute)24, (NSOpenGLPixelFormatAttribute)0};
  NSOpenGLPixelFormat *format = [[[NSOpenGLPixelFormat alloc] initWithAttributes:attributes] autorelease];
  if (format == nil) {
    fprintf(stderr, "[CocoaTerminal] no OpenGL pixel format for the window, drawing with Cairo\n");
    _glUnavailable = YES;
    [super setNeedsDisplay:YES];
    return;
  }
  // The image path's renderer lives in its own context; the surface gets one made in its context.
  delete _glRenderer;
  _glRenderer = NULL;
  _glRendererContext = NULL;
  _glSurface = [[COTGLSurfaceView alloc] initWithFrame:[self bounds] pixelFormat:format terminal:self];
  [_glSurface setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [self addSubview:_glSurface];
  [_glSurface setNeedsDisplay:YES];
}

- (void)detachGLSurface {
  if (_glSurface == nil) {
    return;
  }
  if (_glRendererContext != NULL) {
    if ([[_glSurface openGLContext] view] == _glSurface) {
      [[_glSurface openGLContext] makeCurrentContext];  // so the renderer can delete its objects in it
    }
    delete _glRenderer;
    _glRenderer = NULL;
    _glRendererContext = NULL;
  }
  [_glSurface removeFromSuperview];
  [_glSurface release];
  _glSurface = nil;
  [super setNeedsDisplay:YES];
}

// The surface's drawRect:, with its context current: the frame straight into the window, then swapped.
- (void)drawGLSurface:(NSOpenGLView *)surface {
  _perfDrawCalls += 1;
  NSOpenGLContext *context = [surface openGLContext];
  void *native = [context CGLContextObj];
  BOOL newRenderer = _glRenderer == NULL || _glRendererContext != native;
  if (![self wantsGLSurface] || native == NULL || ![self prepareGLRendererInContext:native]) {
    [self performSelector:@selector(detachGLSurface) withObject:nil afterDelay:0];
    return;
  }
  if (newRenderer) {
    // Swaps wait for the display's refresh, as a terminal should; COCOATERMINAL_GL_VSYNC=0 doesn't, for measuring
    // what a frame costs.
    const char *vsync = getenv("COCOATERMINAL_GL_VSYNC");
    cot::GLRenderer::setSwapInterval(vsync != NULL && strcmp(vsync, "0") == 0 ? 0 : 1);
  }
  cot::GLFrame frame;
  if (![self buildGLFrame:&frame size:[surface bounds].size]) {
    return;
  }
  std::string error;
  if (!_glRenderer->render(frame, nullptr, &error)) {
    fprintf(stderr, "[CocoaTerminal] OpenGL renderer failed, drawing with Cairo: %s\n", error.c_str());
    _glUnavailable = YES;
    [self performSelector:@selector(detachGLSurface) withObject:nil afterDelay:0];
    return;
  }
  NSTimeInterval swapStart = [NSDate timeIntervalSinceReferenceDate];
  [context flushBuffer];
  if (_perfLoggingEnabled) {
    const cot::GLTiming &t = _glRenderer->lastTiming();
    fprintf(stderr, "[CocoaTerminal gl] prepare %.2f ms (%zu new glyphs, %zu in atlas), draw %.2f ms, swap %.2f ms\n",
            t.prepare, t.glyphsRasterised, t.atlasGlyphs, t.draw, ([NSDate timeIntervalSinceReferenceDate] - swapStart) * 1000);
  }
}

- (void)setNeedsDisplay:(BOOL)flag {
  if (flag && _glSurface != nil) {
    [_glSurface setNeedsDisplay:YES];  // it covers the view: only it needs drawing
    return;
  }
  [super setNeedsDisplay:flag];
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
  if (_glSurface != nil) {
    [_glSurface setNeedsDisplay:YES];
    return;
  }
  [super setNeedsDisplayInRect:rect];
}

// The terminal's cells as the renderer wants them, for a view of the given size. NO when the size is empty.
- (BOOL)buildGLFrame:(cot::GLFrame *)out size:(NSSize)size {
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSFont *font = [theme font];
  cot::GLFrame &frame = *out;
  frame.pixelWidth = (int)ceil(size.width);
  frame.pixelHeight = (int)ceil(size.height);
  if (frame.pixelWidth <= 0 || frame.pixelHeight <= 0) {
    return NO;
  }
  frame.background = COTRGB([theme backgroundColor]);
  COTTerminalSnapshot *snapshot = [_session currentSnapshot];
  if (snapshot == nil) {
    return YES;  // just the background
  }
  NSEdgeInsets insets = [theme contentInsets];
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : [font ascender] - [font descender] + [theme lineSpacing];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : [@"M" sizeWithAttributes:_textAttributes].width;
  frame.originX = (float)insets.left;
  frame.originY = (float)insets.top;
  frame.cellWidth = (float)cellWidth;
  frame.cellHeight = (float)lineHeight;
  frame.baseline = (float)([font ascender] + [theme lineSpacing]);  // where Cairo's drawAtPoint: puts it
  frame.background = COTRGB([theme backgroundColor]);
  const std::vector<std::vector<cot::TerminalCell>> &rows = snapshot->cells;
  frame.rows = (int)rows.size();
  frame.columns = 0;
  for (const auto &row : rows) frame.columns = std::max(frame.columns, (int)row.size());
  frame.cells.resize((std::size_t)frame.rows * frame.columns);

  NSInteger selStartRow = 0, selStartCol = 0, selEndRow = 0, selEndCol = 0;
  if (_hasSelection) {
    [self normalizedSelectionStartRow:&selStartRow startColumn:&selStartCol endRow:&selEndRow endColumn:&selEndCol];
  }
  std::uint32_t selection = COTRGB([theme selectionColor]);
  // The palette resolved once per colour, not per cell: NSColor conversions are the slow part of building a frame.
  std::unordered_map<std::uint64_t, std::uint32_t> resolved;
  auto resolve = [&](const cot::TerminalColor &c, BOOL foreground) -> std::uint32_t {
    if (c.kind == cot::TerminalColor::Kind::RGB) {
      return ((std::uint32_t)c.red << 16) | ((std::uint32_t)c.green << 8) | (std::uint32_t)c.blue;
    }
    std::uint64_t key = ((std::uint64_t)(int)c.kind << 40) | ((std::uint64_t)(c.index + 1) << 8) | (foreground ? 1 : 0);
    auto found = resolved.find(key);
    if (found != resolved.end()) return found->second;
    std::uint32_t rgb = COTRGB(COTColorFromTerminalColor(c, theme, foreground));
    resolved.emplace(key, rgb);
    return rgb;
  };
  auto blend = [](std::uint32_t a, std::uint32_t b) -> std::uint32_t {  // halfway, for SGR 2 (dim)
    return (((((a >> 16) & 0xFF) + ((b >> 16) & 0xFF)) / 2) << 16) | (((((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) / 2) << 8) |
           (((a & 0xFF) + (b & 0xFF)) / 2);
  };
  for (int r = 0; r < frame.rows; r++) {
    const std::vector<cot::TerminalCell> &row = rows[(std::size_t)r];
    for (int c = 0; c < (int)row.size(); c++) {
      const cot::TerminalCell &cell = row[(std::size_t)c];
      cot::GLCell &out = frame.cells[(std::size_t)r * frame.columns + c];
      if (cell.continuation) {
        out.width = 0;
        continue;
      }
      out.width = (std::uint8_t)std::max(1, cell.width);
      std::uint32_t fg = resolve(cell.attributes.foreground, YES);
      std::uint32_t bg = resolve(cell.attributes.background, NO);
      BOOL defaultBackground = cell.attributes.background.kind == cot::TerminalColor::Kind::Default;
      if (cell.attributes.inverse) {
        std::swap(fg, bg);
        defaultBackground = NO;
      }
      if (cell.attributes.dim) fg = blend(fg, defaultBackground ? frame.background : bg);
      BOOL inSelection = NO;
      if (_hasSelection) {
        NSInteger first = (r == selStartRow) ? selStartCol : 0;
        NSInteger last = (r == selEndRow) ? selEndCol : (NSInteger)row.size();
        inSelection = r >= selStartRow && r <= selEndRow && c >= first && c < last;
      }
      out.foreground = fg;
      out.background = inSelection ? selection : bg;
      out.drawBackground = inSelection || !defaultBackground;
      out.bold = cell.attributes.bold;
      out.italic = cell.attributes.italic;
      out.underline = cell.attributes.underline;
      out.strike = cell.attributes.strike && !cell.attributes.hidden;
      if (!cell.attributes.hidden && !cell.text.empty() && cell.text != " ") {
        if ((unsigned char)cell.text[0] >= 0x80) {
          NSString *text = [[[NSString alloc] initWithBytes:cell.text.data() length:cell.text.size()
                                                   encoding:NSUTF8StringEncoding] autorelease];
          NSString *drawable = COTDrawableCellText(text ?: @" ");
          out.text = std::string([drawable UTF8String] ?: " ");
          // The renderer picks a colour emoji font for U+FE0F: keep it, and add it to characters that are emoji by
          // default (U+2705 ✅) so they're drawn in colour too, not from a monochrome symbol font.
          UTF32Char first = [drawable length] > 0 ? [drawable characterAtIndex:0] : 0;
          if (first >= 0xD800 && first <= 0xDBFF && [drawable length] > 1) {
            first = 0x10000 + ((first - 0xD800) << 10) + ([drawable characterAtIndex:1] - 0xDC00);
          }
          if (cell.text.find("\xEF\xB8\x8F") != std::string::npos || COTIsDefaultEmoji(first)) out.text += "\xEF\xB8\x8F";
        } else {
          out.text = cell.text;
        }
      }
    }
  }
  if (snapshot->viewportOffset == 0 && [[self window] firstResponder] == self && snapshot->cursorVisible) {
    COTTerminalCursorStyle style = [theme cursorStyle];
    frame.cursorStyle = style == COTTerminalCursorStyleBeam        ? cot::GLCursorStyle::Beam
                        : style == COTTerminalCursorStyleUnderline ? cot::GLCursorStyle::Underline
                                                                   : cot::GLCursorStyle::Block;
    frame.cursorColumn = (int)snapshot->cursorColumn;
    frame.cursorRow = (int)snapshot->cursorRow;
    frame.cursorColour = COTRGB([theme cursorColor]);
    frame.cursorTextColour = frame.background;
  }
  return YES;
}

// The image the renderer reads a frame back into, kept between frames of the same size.
- (NSBitmapImageRep *)glImageForFrame:(const cot::GLFrame &)frame {
  if (_glImage == nil || [_glImage pixelsWide] != frame.pixelWidth || [_glImage pixelsHigh] != frame.pixelHeight) {
    [_glImage release];
    _glImage = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:frame.pixelWidth pixelsHigh:frame.pixelHeight
                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                   colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:frame.pixelWidth * 4
                                                     bitsPerPixel:32];
  }
  return _glImage;
}

// OpenGL in drawRect:. Straight into the window when it can (the surface draws; this draws nothing), else the frame
// rendered off screen and drawn as an image. NO when OpenGL isn't wanted or can't start (no OpenGL 3.3 with
// framebuffers, or a build without it): drawRect: then draws with Cairo.
- (BOOL)drawWithOpenGL {
  if (_glUnavailable || ![self wantsOpenGL]) {
    if (_glSurface != nil) [self performSelector:@selector(detachGLSurface) withObject:nil afterDelay:0];
    return NO;
  }
  if ([self wantsGLSurface]) {
    if (_glSurface == nil) {
      // Not from inside drawing: added next time round the run loop. Cairo draws this once.
      [self performSelector:@selector(attachGLSurface) withObject:nil afterDelay:0];
      return NO;
    }
    return YES;
  }
  if (_glSurface != nil) {
    [self performSelector:@selector(detachGLSurface) withObject:nil afterDelay:0];
    return NO;
  }
  if (![self prepareGLRendererInContext:NULL]) {
    return NO;
  }
  NSRect bounds = [self bounds];
  cot::GLFrame frame;
  if (![self buildGLFrame:&frame size:bounds.size]) {
    return YES;
  }
  [self glImageForFrame:frame];
  std::string error;
  if (!_glRenderer->render(frame, [_glImage bitmapData], &error)) {
    fprintf(stderr, "[CocoaTerminal] OpenGL renderer failed, drawing with Cairo: %s\n", error.c_str());
    _glUnavailable = YES;
    return NO;
  }
  NSTimeInterval blitStart = [NSDate timeIntervalSinceReferenceDate];
  [_glImage drawInRect:bounds];
  if (_perfLoggingEnabled) {
    const cot::GLTiming &t = _glRenderer->lastTiming();
    fprintf(stderr, "[CocoaTerminal gl] prepare %.2f ms (%zu new glyphs, %zu in atlas), draw %.2f ms, readback %.2f ms, image %.2f ms\n",
            t.prepare, t.glyphsRasterised, t.atlasGlyphs, t.draw, t.readback,
            ([NSDate timeIntervalSinceReferenceDate] - blitStart) * 1000);
  }
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  _perfDrawCalls += 1;
  if ([self drawWithOpenGL]) {
    return;
  }
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSColor *backgroundColor = [theme backgroundColor];
  if ([theme opacity] < 1.0) {
    backgroundColor = [backgroundColor colorWithAlphaComponent:[theme opacity]];
  }
  [backgroundColor setFill];
  NSRectFill(dirtyRect);

  COTTerminalSnapshot *snapshot = [_session currentSnapshot];
  if (snapshot == nil) {
    return;
  }
  const std::vector<std::vector<cot::TerminalCell>> &rows = snapshot->cells;

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
    std::string runText;
    bool runHasNonASCII = false;
    NSDictionary *runAttributes = nil;
    auto flushRun = [&]() {
      if (runText.empty()) {
        return;
      }
      NSString *text = [[[NSString alloc] initWithBytes:runText.data()
                                                 length:runText.size()
                                               encoding:NSUTF8StringEncoding] autorelease];
      if (text == nil) {
        text = @" ";
      }
      if (runHasNonASCII) {
        text = COTDrawableCellText(text);
        runHasNonASCII = false;
      }
      NSAttributedString *piece = [[NSAttributedString alloc] initWithString:text attributes:runAttributes ?: _textAttributes];
      [line appendAttributedString:piece];
      [piece release];
      runText.clear();
    };

    NSInteger lastContentColumn = (NSInteger)row.size();
    if (!drawSelection) {
      lastContentColumn = 0;
      NSInteger scanColumn = 0;
      for (std::size_t i = 0; i < row.size(); ++i) {
        const cot::TerminalCell &cell = row[i];
        if (cell.continuation) {
          scanColumn += 1;
          continue;
        }
        int cellWidthCells = std::max(1, cell.width);
        BOOL defaultForegroundCell = (cell.attributes.foreground.kind == cot::TerminalColor::Kind::Default);
        BOOL defaultBackgroundCell = (cell.attributes.background.kind == cot::TerminalColor::Kind::Default);
        BOOL blankDefaultCell = defaultForegroundCell && defaultBackgroundCell &&
          !cell.attributes.inverse && !cell.attributes.underline && !cell.attributes.strike && cell.text == " ";
        if (!blankDefaultCell) {
          lastContentColumn = scanColumn + cellWidthCells;
        }
        scanColumn += cellWidthCells;
      }
    }

    for (std::size_t i = 0; i < row.size(); ++i) {
      const cot::TerminalCell &cell = row[i];
      if (cell.continuation) {
        columnIndex += 1;
        continue;
      }
      if (!drawSelection && columnIndex >= lastContentColumn) {
        break;
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
      // SGR 2: the foreground halfway to the cell's background, as Alacritty draws it (bold + dim: the bold face, dimmed).
      if (cell.attributes.dim) {
        NSColor *under = defaultBackground ? [theme backgroundColor] : background;
        foreground = [foreground blendedColorWithFraction:0.5 ofColor:under] ?: foreground;
      }
      BOOL hidden = cell.attributes.hidden;  // SGR 8: the cell's background, no text
      BOOL inSelection = NO;
      if (drawSelection) {
        NSInteger firstColInRow = (rowIndex == selStartRow) ? selStartCol : 0;
        NSInteger lastColInRow = (rowIndex == selEndRow) ? selEndCol : (NSInteger)row.size();
        inSelection = (rowIndex >= selStartRow && rowIndex <= selEndRow &&
                       columnIndex >= firstColInRow && columnIndex < lastColInRow);
      }
      // Backgrounds on whole pixels, as the OpenGL renderer's: neighbouring cells meet without a seam.
      NSRect cellRect = NSMakeRect(x, y, cellRectWidth, lineHeight);
      if (inSelection) {
        [selectionColor setFill];
        NSRectFill(COTSnappedCellRect(cellRect));
      } else if (!defaultBackground) {
        [background setFill];
        NSRectFill(COTSnappedCellRect(cellRect));
      }

      NSFont *cellFont = [self fontForBold:cell.attributes.bold italic:cell.attributes.italic];
      // Box drawing and block elements as rectangles (COTCairoCells), so lines join across cells and rows; the line of
      // text gets spaces in their place.
      BOOL drawnHere = NO;
      if (!hidden && cell.text.size() == 3 && (unsigned char)cell.text[0] == 0xE2) {
        UTF32Char code = ((UTF32Char)(cell.text[0] & 0x0F) << 12) | ((UTF32Char)(cell.text[1] & 0x3F) << 6) |
                         (UTF32Char)(cell.text[2] & 0x3F);
        NSColor *behind = inSelection ? selectionColor : (defaultBackground ? [theme backgroundColor] : background);
        drawnHere = COTDrawBoxCell(code, cellRect, foreground, behind);
      }
      // Emoji, and anything above U+FFFF, drawn by Cairo straight from fontconfig's font (COTCairoCells): GNUstep's
      // text drawing has no glyph above U+FFFF, so 🚀 came out blank. In colour from a colour emoji font if there is one.
      if (!hidden && !drawnHere && !cell.text.empty() && (unsigned char)cell.text[0] >= 0xE2) {
        NSString *text = [[[NSString alloc] initWithBytes:cell.text.data() length:cell.text.size() encoding:NSUTF8StringEncoding] autorelease];
        UTF32Char code = [text length] > 0 ? [text characterAtIndex:0] : 0;
        if ([text length] > 1 && code >= 0xD800 && code <= 0xDBFF)
          code = 0x10000 + ((code - 0xD800) << 10) + ([text characterAtIndex:1] - 0xDC00);
        BOOL emoji = (COTContainsCharacter(text, 0xFE0F) || COTIsDefaultEmoji(code)) && !COTContainsCharacter(text, 0xFE0E);
        if (emoji || code >= 0x10000)
          drawnHere = COTDrawCairoGlyphCell(cell.text, code, emoji, [cellFont familyName], [cellFont pointSize], cellRect, foreground);
      }
      NSString *cellString = nil;
      NSFont *fallback = nil;
      if (!hidden && !drawnHere && !cell.text.empty() && (unsigned char)cell.text[0] >= 0x80) {
        cellString = [[[NSString alloc] initWithBytes:cell.text.data() length:cell.text.size() encoding:NSUTF8StringEncoding] autorelease];
        fallback = [self fallbackFontFor:cellString font:cellFont cellWidth:cellRectWidth lineHeight:lineHeight];
      }
      if (fallback) {
        // Drawn on its own, centred in its cell; the line so far is drawn first and the rest starts after this cell.
        flushRun();
        [line drawAtPoint:NSMakePoint(lineStartX, y)];
        [line release];
        line = [[NSMutableAttributedString alloc] init];
        runAttributes = nil;
        NSDictionary *glyphAttrs = [NSDictionary dictionaryWithObjectsAndKeys:fallback, NSFontAttributeName, foreground, NSForegroundColorAttributeName, nil];
        NSString *drawable = COTDrawableCellText(cellString);
        NSSize size = [drawable sizeWithAttributes:glyphAttrs];
        [drawable drawAtPoint:NSMakePoint(x + MAX(0, (cellRectWidth - size.width) / 2), y + MAX(0, (lineHeight - size.height) / 2))
                 withAttributes:glyphAttrs];
        lineStartX = x + cellRectWidth;
      } else {
        NSDictionary *attrs = ([foreground isEqual:defaultForeground] && cellFont == font)
          ? _textAttributes
          : [NSDictionary dictionaryWithObjectsAndKeys:cellFont, NSFontAttributeName, foreground, NSForegroundColorAttributeName, nil];
        if (runAttributes != nil && ![runAttributes isEqual:attrs]) {
          flushRun();
        }
        runAttributes = attrs;
        runText += (hidden || drawnHere) ? std::string((std::size_t)cellWidthCells, ' ') : cell.text;
        if (!hidden && !drawnHere && !cell.text.empty() && cell.text.size() > 1) runHasNonASCII = true;
      }

      if (cell.attributes.underline) {
        flushRun();
        [foreground setFill];
        NSRectFill(NSMakeRect(x, y, cellRectWidth, 1.0));
      }
      if (cell.attributes.strike && !hidden) {  // SGR 9: a line through the middle of the text
        flushRun();
        [foreground setFill];
        NSRectFill(NSMakeRect(x, y + floor(lineHeight * 0.45), cellRectWidth, 1.0));
      }

      x += cellRectWidth;
      columnIndex += cellWidthCells;
    }
    flushRun();
    [line drawAtPoint:NSMakePoint(lineStartX, y)];
    [line release];
    y -= lineHeight;
    if (y < NSMinY([self bounds]) + insets.bottom) {
      break;
    }
  }

  if (snapshot->viewportOffset == 0 && [[self window] firstResponder] == self && snapshot->cursorVisible) {
    CGFloat cursorX = insets.left + (CGFloat)snapshot->cursorColumn * cellWidth;
    CGFloat cursorY = firstBaselineY - (CGFloat)snapshot->cursorRow * lineHeight;
    NSRect cursorRect = NSMakeRect(cursorX, cursorY, cellWidth, lineHeight);
    COTTerminalCursorStyle style = [theme cursorStyle];
    if (style == COTTerminalCursorStyleBeam) {
      [[theme cursorColor] setFill];
      NSRectFill(NSMakeRect(cursorX, cursorY, 2.0, lineHeight));
    } else if (style == COTTerminalCursorStyleUnderline) {
      [[theme cursorColor] setFill];
      NSRectFill(NSMakeRect(cursorX, cursorY + lineHeight - 2.0, cellWidth, 2.0));
    } else {
      [[theme cursorColor] setFill];
      NSRectFill(cursorRect);
      NSUInteger cursorRow = snapshot->cursorRow;
      NSUInteger cursorColumn = snapshot->cursorColumn;
      NSString *cursorText = @" ";
      NSFont *cursorFont = font;
      std::string cursorUTF8;
      int cursorCells = 1;
      if (cursorRow < rows.size() && cursorColumn < rows[cursorRow].size()) {
        const cot::TerminalCell &cell = rows[cursorRow][cursorColumn];
        cursorFont = [self fontForBold:cell.attributes.bold italic:cell.attributes.italic];
        if (!cell.continuation && !cell.text.empty()) {
          cursorUTF8 = cell.text;
          cursorCells = std::max(1, cell.width);
          NSString *temp = [[NSString alloc] initWithBytes:cell.text.data()
                                                    length:cell.text.size()
                                                  encoding:NSUTF8StringEncoding];
          if (temp != nil) {
            cursorText = [temp autorelease];
          }
        }
      }
      // Box drawing and emoji under the cursor: drawn as in any other cell, in the cursor's text colour.
      UTF32Char cursorCode = [cursorText length] > 0 ? [cursorText characterAtIndex:0] : 0;
      if ([cursorText length] > 1 && cursorCode >= 0xD800 && cursorCode <= 0xDBFF)
        cursorCode = 0x10000 + ((cursorCode - 0xD800) << 10) + ([cursorText characterAtIndex:1] - 0xDC00);
      BOOL cursorEmoji = (COTContainsCharacter(cursorText, 0xFE0F) || COTIsDefaultEmoji(cursorCode)) &&
                         !COTContainsCharacter(cursorText, 0xFE0E);
      NSRect cursorCellRect = NSMakeRect(cursorX, cursorY, cellWidth * cursorCells, lineHeight);
      BOOL cursorDrawn = COTDrawBoxCell(cursorCode, cursorRect, [theme backgroundColor], [theme cursorColor]);
      if (!cursorDrawn && (cursorEmoji || cursorCode >= 0x10000) && !cursorUTF8.empty())
        cursorDrawn = COTDrawCairoGlyphCell(cursorUTF8, cursorCode, cursorEmoji, [cursorFont familyName], [cursorFont pointSize],
                                            cursorCellRect, [theme backgroundColor]);
      if (!cursorDrawn) {
        NSMutableDictionary *cursorAttributes = [NSMutableDictionary dictionaryWithDictionary:_textAttributes];
        [cursorAttributes setObject:[theme backgroundColor] forKey:NSForegroundColorAttributeName];
        [cursorAttributes setObject:cursorFont forKey:NSFontAttributeName];
        [cursorText drawAtPoint:NSMakePoint(cursorX, cursorY) withAttributes:cursorAttributes];
      }
    }
  }
  NSString *transportError = [_session transportError];
  if ([transportError length]) {
    [backgroundColor setFill];
    NSRectFill(NSMakeRect(NSMinX([self bounds]), NSMinY([self bounds]), NSWidth([self bounds]), 22));
    [transportError drawAtPoint:NSMakePoint(NSMinX([self bounds])+8, NSMinY([self bounds])+4)
      withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],
                       NSForegroundColorAttributeName:[NSColor redColor]}];
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
  NSString *baseCharacters = [event charactersIgnoringModifiers];
  NSString *sequence = nil;
  if ([baseCharacters length] > 0) {
    sequence = COTSequenceForFunctionKey([baseCharacters characterAtIndex:0]);
  }
  if (sequence == nil && [characters length] > 0) {
    sequence = COTSequenceForFunctionKey([characters characterAtIndex:0]);
  }
  if (sequence == nil && COTIsBackTab(event)) {
    sequence = @"\033[Z";
  }
  switch (COTMacKeyCode(event)) {
  case 123:
    if (sequence == nil) { sequence = @"\033[D"; }
    break;
  case 124:
    if (sequence == nil) { sequence = @"\033[C"; }
    break;
  case 125:
    if (sequence == nil) { sequence = @"\033[B"; }
    break;
  case 126:
    if (sequence == nil) { sequence = @"\033[A"; }
    break;
  case 115:
    if (sequence == nil) { sequence = @"\033[H"; }
    break;
  case 119:
    if (sequence == nil) { sequence = @"\033[F"; }
    break;
  case 116:
    if (sequence == nil) { sequence = @"\033[5~"; }
    break;
  case 121:
    if (sequence == nil) { sequence = @"\033[6~"; }
    break;
  case 51:
    if (sequence == nil) { sequence = @"\177"; }
    break;
  case 117:
    if (sequence == nil) { sequence = @"\033[3~"; }
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

  // Treat Cmd as Ctrl-equivalent for terminal control bytes. On GNUstep on Linux,
  // the physical Ctrl key is commonly mapped to NSEventModifierFlagCommand; on macOS it maps
  // to NSEventModifierFlagControl. Either way, bare modifier+letter (no Shift) means a
  // terminal control byte. Shift-modified variants are reserved for app shortcuts.
  if ([self sendTerminalControlBytesForEvent:event debug:debugKeys]) {
    return;
  }

  NSUInteger flags = [event modifierFlags];
  BOOL hasCtrl = (flags & NSEventModifierFlagControl) != 0;
  BOOL hasCmd = (flags & NSEventModifierFlagCommand) != 0;
  BOOL hasAlt = (flags & NSEventModifierFlagOption) != 0;

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
  // Ctrl-click (Cmd-click on a Mac; GNUstep often reports the Ctrl key as Command) opens a link, even in a program
  // that takes the mouse.
  if ([event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) {
    NSURL *link = [self linkForEvent:event];
    if (link != nil) {
      [self openLink:link];
      return;
    }
  }
  BOOL shift = ([event modifierFlags] & NSEventModifierFlagShift) != 0;
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

// The URL under the pointer, from the cells on screen.
- (NSURL *)linkForEvent:(NSEvent *)event {
  NSInteger row = 0;
  NSInteger column = 0;
  [self cellCoordinatesForEvent:event row:&row column:&column];
  return [self linkAtRow:(NSUInteger)row column:(NSUInteger)column];
}

- (NSURL *)linkAtRow:(NSUInteger)row column:(NSUInteger)column {
  COTTerminalSnapshot *snapshot = [_session currentSnapshot];
  if (snapshot == nil || row >= snapshot->cells.size()) {
    return nil;
  }
  std::string url = cot::urlAtColumn(snapshot->cells[row], column);
  if (url.empty()) {
    return nil;
  }
  NSString *string = [NSString stringWithUTF8String:url.c_str()];
  NSURL *link = string != nil ? [NSURL URLWithString:string] : nil;
  if (link == nil && string != nil) {  // non-ASCII characters: percent-encode them
    NSString *escaped = [string stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    link = escaped != nil ? [NSURL URLWithString:escaped] : nil;
  }
  return link;
}

- (BOOL)openLink:(NSURL *)url {
  if (url == nil) {
    return NO;
  }
#if defined(_WIN32)
  // GNUstep's NSWorkspace on Windows has no handler for web links: let the shell open it.
  NSString *string = [url absoluteString];
  std::wstring wide;
  for (NSUInteger i = 0; i < [string length]; i++) {
    wide.push_back((wchar_t)[string characterAtIndex:i]);
  }
  HINSTANCE result = ShellExecuteW(NULL, L"open", wide.c_str(), NULL, NULL, SW_SHOWNORMAL);
  return (INT_PTR)result > 32;
#else
  if ([[NSWorkspace sharedWorkspace] openURL:url]) {
    return YES;
  }
#if !defined(__APPLE__)
  // GNUstep's NSWorkspace knows no browser unless one is set up: hand it to the desktop's opener.
  @try {
    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/xdg-open" arguments:[NSArray arrayWithObject:[url absoluteString]]];
    return YES;
  } @catch (NSException *exception) {
    (void)exception;
  }
#endif
  return NO;
#endif
}

#pragma mark - Search

- (BOOL)findPrevious:(NSString *)text {
  return [self findText:text backwards:YES];
}

- (BOOL)findNext:(NSString *)text {
  return [self findText:text backwards:NO];
}

- (BOOL)findCaseSensitive {
  return _findCaseSensitive;
}

- (void)setFindCaseSensitive:(BOOL)caseSensitive {
  if (_findCaseSensitive != caseSensitive) {
    _findCaseSensitive = caseSensitive;
    _findLine = NSNotFound;
  }
}

- (BOOL)findText:(NSString *)text backwards:(BOOL)backwards {
  if ([text length] == 0) {
    _findLine = NSNotFound;
    return NO;
  }
  // The same text (in any case, when case is ignored) carries on from the last match; a new one starts again.
  BOOL same = _findText != nil && (_findCaseSensitive ? [text isEqualToString:_findText]
                                                      : [text caseInsensitiveCompare:_findText] == NSOrderedSame);
  if (!same) {
    [_findText release];
    _findText = [text copy];
    _findLine = NSNotFound;
  }
  // A new search starts from the end: upward it finds the newest match, downward the oldest.
  NSUInteger fromLine = NSUIntegerMax;
  NSUInteger fromColumn = 0;
  if (_findLine != NSNotFound) {
    fromLine = _findLine;
    fromColumn = backwards ? _findColumn : _findColumn + 1;
  }
  NSUInteger line = 0, column = 0, width = 0;
  if (![_session findText:text fromLine:fromLine column:fromColumn backwards:backwards ignoreCase:!_findCaseSensitive
                matchLine:&line matchColumn:&column matchWidth:&width]) {
    _findLine = NSNotFound;
    [self clearSelection];
    return NO;
  }
  _findLine = line;
  _findColumn = column;
  [self revealLine:line column:column width:width];
  return YES;
}

// Scrolls a line into view (the middle of it, if it was out of sight) and selects the cells of the match.
- (void)revealLine:(NSUInteger)line column:(NSUInteger)column width:(NSUInteger)width {
  NSInteger rows = (NSInteger)[_session rows];
  NSInteger lineCount = (NSInteger)[_session lineCount];  // after any earlier scroll: the queue runs in order
  NSInteger scrollback = MAX((NSInteger)0, lineCount - rows);
  NSInteger offset = (NSInteger)[_session viewportOffset];
  NSInteger top = scrollback - offset;  // the line in the view's first row
  if ((NSInteger)line < top || (NSInteger)line >= top + rows) {
    offset = MIN(scrollback, MAX((NSInteger)0, scrollback - (NSInteger)line + rows / 2));
    [_session setViewportOffset:(NSUInteger)offset];
    (void)[_session lineCount];  // waits for the terminal queue: the scrolled screen is published when this returns
    top = scrollback - offset;
  }
  NSInteger row = (NSInteger)line - top;
  _selectingLocally = NO;
  _selectionAnchorRow = row;
  _selectionAnchorColumn = (NSInteger)column;
  _selectionCurrentRow = row;
  _selectionCurrentColumn = (NSInteger)(column + MAX(width, (NSUInteger)1));
  _hasSelection = YES;
  [self setNeedsDisplay:YES];
}

#pragma mark - Find bar

- (BOOL)isFindBarVisible {
  return _findField != nil;
}

- (void)showFindBar {
  if (_findField == nil) {
    _findField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [_findField setEditable:YES];
    [_findField setBezeled:YES];
    [_findField setTarget:self];
    [_findField setAction:@selector(findBarAction:)];
    [_findField setDelegate:(id)self];
    if ([_findField respondsToSelector:@selector(setPlaceholderString:)]) {
      [(id)_findField setPlaceholderString:@"Find (Enter: older, Shift+Enter: newer, Esc: close)"];
    }
    [_findField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    if ([_findText length] > 0) {
      [_findField setStringValue:_findText];
    }
    [self detachGLSurface];  // its child window would cover the field
    [self layoutFindBar];
    [self addSubview:_findField];
  }
  // No spell checking in a search field.
  NSText *editor = [[self window] fieldEditor:YES forObject:_findField];
  if ([editor respondsToSelector:@selector(setContinuousSpellCheckingEnabled:)]) {
    [(NSTextView *)editor setContinuousSpellCheckingEnabled:NO];
  }
  [[self window] makeFirstResponder:_findField];
  if ([_findField respondsToSelector:@selector(selectText:)]) {
    [_findField selectText:nil];
  }
}

- (void)hideFindBar {
  if (_findField == nil) {
    return;
  }
  [_findField setDelegate:nil];
  [_findField setTarget:nil];
  [_findField removeFromSuperview];
  [_findField autorelease];  // it may be the one sending us this
  _findField = nil;
  [[self window] makeFirstResponder:self];
  [self setNeedsDisplay:YES];  // the surface comes back on the next draw
}

- (void)layoutFindBar {
  NSRect bounds = [self bounds];
  CGFloat height = 24;
  CGFloat width = MIN((CGFloat)320, NSWidth(bounds) - 16);
  [_findField setFrame:NSMakeRect(NSMaxX(bounds) - width - 8, [self isFlipped] ? 6 : NSMaxY(bounds) - height - 6, width,
                                  height)];
}

- (void)findBarAction:(id)sender {
  (void)sender;
  BOOL shift = ([[NSApp currentEvent] modifierFlags] & NSShiftKeyMask) != 0;
  [self showFindResult:[self findText:[_findField stringValue] backwards:!shift]];
}

- (void)showFindResult:(BOOL)found {
  [_findField setTextColor:(found || [[_findField stringValue] length] == 0) ? [NSColor textColor] : [NSColor redColor]];
}

// Each keystroke searches again from the newest output.
- (void)controlTextDidChange:(NSNotification *)notification {
  if ([notification object] != _findField) {
    return;
  }
  _findLine = NSNotFound;
  [self showFindResult:[self findText:[_findField stringValue] backwards:YES]];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
  (void)textView;
  if (control == _findField && (command == @selector(cancelOperation:) || command == @selector(complete:))) {
    [self hideFindBar];
    return YES;
  }
  return NO;
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
    return [_session allowsLocalCopy] && _hasSelection;
  }
  if (action == @selector(paste:)) return [_session allowsInput];
  if (action == @selector(selectAll:)) {
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
  if (![_session allowsLocalCopy]) return;
  NSString *text = [self selectedText];
  if ([text length] == 0) {
    return;
  }
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard declareTypes:[NSArray arrayWithObject:COTPasteboardTypeString] owner:nil];
  [pasteboard setString:text forType:COTPasteboardTypeString];
}

- (void)pasteFromClipboard {
  if (![_session allowsInput]) return;
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  NSString *text = [pasteboard stringForType:COTPasteboardTypeString];
  if ([text length] == 0) {
    return;
  }
  NSMutableString *normalized = [NSMutableString stringWithString:text];
  [normalized replaceOccurrencesOfString:@"\r\n" withString:@"\r" options:0 range:NSMakeRange(0, [normalized length])];
  [normalized replaceOccurrencesOfString:@"\n" withString:@"\r" options:0 range:NSMakeRange(0, [normalized length])];
  if ([_session isBracketedPasteEnabled]) {
    NSString *transaction = [NSString stringWithFormat:@"\033[200~%@\033[201~", normalized];
    [_session sendInput:[transaction dataUsingEncoding:NSUTF8StringEncoding]];
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
  [self scheduleTerminalSizeUpdate];
}

- (void)viewFrameDidChange:(NSNotification *)notification {
  (void)notification;
  [self scheduleTerminalSizeUpdate];
  [self setNeedsDisplay:YES];
}

- (BOOL)sendTerminalControlBytesForEvent:(NSEvent *)event debug:(BOOL)debugKeys {
  NSString *characters = [event characters];
  NSUInteger flags = [event modifierFlags];
  BOOL hasCtrl = (flags & NSEventModifierFlagControl) != 0;
  BOOL hasCmd = (flags & NSEventModifierFlagCommand) != 0;
  BOOL hasShift = (flags & NSEventModifierFlagShift) != 0;
  BOOL hasAlt = (flags & NSEventModifierFlagOption) != 0;

  if (!(hasCtrl || hasCmd) || hasShift || [characters length] == 0) {
    return NO;
  }
  if (COTIsAltGrText(event)) {
    return NO;  // text from the layout's AltGr level (Windows reports AltGr as Ctrl+Alt): typed as it is
  }

  unichar first = [characters characterAtIndex:0];
  if (first >= 0x01 && first <= 0x1f) {
    unsigned char control = (unsigned char)first;
    [_session sendInput:[NSData dataWithBytes:&control length:1]];
    if (debugKeys) {
      fprintf(stderr, "[COT key]   -> sent existing control byte 0x%02x\n", control);
      fflush(stderr);
    }
    return YES;
  }

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

  if (!translated) {
    return NO;
  }

  if (hasAlt) {
    unsigned char esc = 0x1b;
    [_session sendInput:[NSData dataWithBytes:&esc length:1]];
  }
  [_session sendInput:[NSData dataWithBytes:&control length:1]];
  if (debugKeys) {
    fprintf(stderr, "[COT key]   -> translated to control byte 0x%02x\n", control);
    fflush(stderr);
  }
  return YES;
}

- (BOOL)handleClipboardShortcut:(NSEvent *)event {
  NSUInteger flags = [event modifierFlags];
  BOOL hasCmd = (flags & NSEventModifierFlagCommand) != 0;
  BOOL hasShift = (flags & NSEventModifierFlagShift) != 0;
  // Require Cmd+Shift so we never collide with terminal-control Ctrl+letter
  // (on GNUstep the physical Ctrl key often delivers NSEventModifierFlagCommand, so bare
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
  if ([chars isEqualToString:@"f"]) {
    [self showFindBar];
    return YES;
  }
  return NO;
}

- (BOOL)handleScrollbackShortcut:(NSEvent *)event {
  NSUInteger flags = [event modifierFlags];
  BOOL hasCmd = (flags & NSEventModifierFlagCommand) != 0;
  BOOL hasShift = (flags & NSEventModifierFlagShift) != 0;
  if (!hasCmd && !hasShift) {
    return NO;
  }
  NSInteger pageStep = MAX((NSInteger)1, (NSInteger)([_session rows] / 2));
  unsigned short keyCode = COTMacKeyCode(event);
  // Cmd/Ctrl+Shift+Up and Down: to the previous or next prompt (shell integration).
  if (hasCmd && hasShift && (keyCode == 126 || keyCode == 125)) {
    if (keyCode == 126) {
      [self scrollToPreviousPrompt];
    } else {
      [self scrollToNextPrompt];
    }
    return YES;
  }
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

// Shell integration: puts the previous (older) or next prompt at the top of the view. NO if there's none that way.
- (BOOL)scrollToPreviousPrompt {
  return [self scrollToPromptBackwards:YES];
}

- (BOOL)scrollToNextPrompt {
  return [self scrollToPromptBackwards:NO];
}

- (BOOL)scrollToPromptBackwards:(BOOL)backwards {
  NSArray<NSNumber *> *prompts = [_session promptLines];  // waits for the terminal queue: the snapshot below is current
  NSInteger scrollback = (NSInteger)[_session scrollbackLineCount];
  NSInteger top = scrollback - (NSInteger)[_session viewportOffset];  // the line in the view's first row
  NSInteger target = -1;
  for (NSNumber *number in prompts) {
    NSInteger line = (NSInteger)[number unsignedIntegerValue];
    if (backwards && line < top) target = line;  // the last one above
    if (!backwards && line > top) {
      target = line;  // the first one below
      break;
    }
  }
  if (target < 0) {
    if (!backwards && [_session viewportOffset] > 0) {
      [_session scrollToBottom];  // past the last prompt: back to the live screen
      return YES;
    }
    return NO;
  }
  [_session setViewportOffset:(NSUInteger)MAX((NSInteger)0, scrollback - target)];
  return YES;
}

- (BOOL)handleZoomShortcut:(NSEvent *)event {
  NSUInteger flags = [event modifierFlags];
  BOOL ctrl = (flags & NSEventModifierFlagControl) != 0;
  BOOL cmd = (flags & NSEventModifierFlagCommand) != 0;
  if ((!ctrl && !cmd) || COTIsAltGrText(event)) {
    return NO;  // AltGr+0 is } on a German layout, not "reset zoom"
  }

  NSString *characters = [event characters];
  NSString *charactersIgnoringModifiers = [event charactersIgnoringModifiers];
  unichar character = [characters length] > 0 ? [characters characterAtIndex:0] : 0;
  unichar baseCharacter = [charactersIgnoringModifiers length] > 0 ? [charactersIgnoringModifiers characterAtIndex:0] : 0;
  unsigned short keyCode = COTMacKeyCode(event);

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
  [_fallbackFonts removeAllObjects];

  NSFontManager *manager = [NSFontManager sharedFontManager];
  for (int i = 0; i < 4; ++i) {
    NSFont *styled = font;
    if (i != 0 && font != nil) {
      NSFontTraitMask traits = ((i & 1) ? NSBoldFontMask : 0) | ((i & 2) ? NSItalicFontMask : 0);
      NSFont *converted = [manager convertFont:font toHaveTrait:traits];
      NSFontTraitMask got = converted != nil ? [manager traitsOfFont:converted] : 0;
      CGFloat advance = converted != nil
        ? [@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:converted forKey:NSFontAttributeName]].width
        : 0.0;
      if (converted != nil && converted != font && (got & traits) == traits && fabs(advance - _cellWidth) < 0.5) {
        styled = converted;
      }
    }
    [_styledFonts[i] release];
    _styledFonts[i] = [styled retain];
  }
}

// A cell whose character `font` hasn't got: fontconfig's covering font, at a size that fits the cell, so the grid never
// shifts; nil when `font` has it (or nothing better is found). Cached per character until the font changes.
- (NSFont *)fallbackFontFor:(NSString *)text font:(NSFont *)font cellWidth:(CGFloat)cellWidth lineHeight:(CGFloat)lineHeight {
#if defined(__APPLE__)
  (void)text; (void)font; (void)cellWidth; (void)lineHeight;
  return nil;  // Core Text cascades on its own
#else
  if (text.length == 0 || [text characterAtIndex:0] < 0x80) return nil;
  UTF32Char character = [text characterAtIndex:0];
  unichar low = text.length > 1 ? [text characterAtIndex:1] : 0;
  if (character >= 0xD800 && character <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF)
    character = 0x10000 + ((character - 0xD800) << 10) + (low - 0xDC00);
  // As emoji: by default, or asked for with U+FE0F. Then a colour font even when the terminal's font has a plain glyph.
  BOOL emoji = (COTContainsCharacter(text, 0xFE0F) || COTIsDefaultEmoji(character)) && !COTContainsCharacter(text, 0xFE0E);
  NSCharacterSet *covered = [font coveredCharacterSet];
  if (!emoji && (!covered || [covered longCharacterIsMember:character])) return nil;
  NSString *key = [NSString stringWithFormat:@"%u %@ %.1f %d", (unsigned)character, [font fontName], [font pointSize], (int)emoji];
  if (!_fallbackFonts) _fallbackFonts = [[NSMutableDictionary alloc] init];
  id cached = [_fallbackFonts objectForKey:key];
  if (cached) return cached == [NSNull null] ? nil : cached;
  NSFont *fallback = nil;
  NSString *name = COTFallbackFontName(character, [font familyName], emoji);
  if (name) fallback = [NSFont fontWithName:name size:[font pointSize]];
  if (fallback) {
    // Fit the cell: no wider than it, no taller than the line.
    CGFloat width = [COTDrawableCellText(text) sizeWithAttributes:[NSDictionary dictionaryWithObject:fallback forKey:NSFontAttributeName]].width;
    CGFloat height = [fallback ascender] - [fallback descender];
    CGFloat scale = MIN(1.0, MIN(width > 0 ? cellWidth / width : 1.0, height > 0 ? lineHeight / height : 1.0));
    if (scale < 0.999) fallback = [NSFont fontWithName:name size:floor([font pointSize] * scale * 10) / 10] ?: fallback;
  }
  [_fallbackFonts setObject:fallback ?: (id)[NSNull null] forKey:key];
  return fallback;
#endif
}

- (NSFont *)fontForBold:(BOOL)bold italic:(BOOL)italic {
  NSFont *styled = _styledFonts[(bold ? 1 : 0) | (italic ? 2 : 0)];
  return styled != nil ? styled : [[[_session configuration] theme] font];
}

- (void)updateTerminalSizeFromBounds {
  if (_session == nil || [_session fixedGrid]) {
    return;
  }
  COTTerminalTheme *theme = [[_session configuration] theme];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : MAX([@"M" sizeWithAttributes:_textAttributes].width, 1.0);
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : MAX([[theme font] ascender] - [[theme font] descender] + [theme lineSpacing], 1.0);
  NSEdgeInsets insets = [theme contentInsets];
  NSRect bounds = [self bounds];
  if (!isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
      !isfinite(cellWidth) || !isfinite(lineHeight) ||
      bounds.size.width <= 0.0 || bounds.size.height <= 0.0 ||
      cellWidth <= 0.0 || lineHeight <= 0.0) {
    return;
  }
  CGFloat usableWidth = bounds.size.width - insets.left - insets.right;
  CGFloat usableHeight = bounds.size.height - insets.top - insets.bottom;
  if (!isfinite(usableWidth) || !isfinite(usableHeight) ||
      usableWidth < cellWidth || usableHeight < lineHeight) {
    return;
  }
  NSUInteger columns = MIN(MAX((NSUInteger)floor(usableWidth / cellWidth), 1), COTTerminalMaximumColumns);
  NSUInteger rows = MIN(MAX((NSUInteger)floor(usableHeight / lineHeight), 1), COTTerminalMaximumRows);
  if (columns != [_session columns] || rows != [_session rows]) {
    [_session resizeToColumns:columns rows:rows];
  }
}

- (void)scheduleTerminalSizeUpdate {
  _terminalSizeUpdateScheduled = YES;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performPendingTerminalSizeUpdate) object:nil];
  NSTimeInterval delay = [_session isRunning] ? 0.15 : 0.0;
  [self performSelector:@selector(performPendingTerminalSizeUpdate) withObject:nil afterDelay:delay];
}

- (void)performPendingTerminalSizeUpdate {
  _terminalSizeUpdateScheduled = NO;
  [self updateTerminalSizeFromBounds];
}

- (void)setZoomFontSize:(CGFloat)fontSize {
  COTTerminalTheme *theme = [[_session configuration] theme];
  CGFloat clamped = MIN(MAX(fontSize, 8.0), 32.0);
  if (fabs([theme fontSize] - clamped) < 0.01) {
    return;
  }
  [theme setFontSize:clamped];
  [self rebuildTextAttributes];
  [self scheduleTerminalSizeUpdate];
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

- (void)applyTheme:(COTTerminalTheme *)theme {
  if (theme == nil || _session == nil) {
    return;
  }
  COTTerminalTheme *copy = [theme copy];
  [[_session configuration] setTheme:copy];
  _baseFontSize = [copy fontSize];
  [copy release];
  [self rebuildTextAttributes];
  // Now, not after the usual settle delay: the caller sees the new size as soon as this returns.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performPendingTerminalSizeUpdate) object:nil];
  _terminalSizeUpdateScheduled = NO;
  [self updateTerminalSizeFromBounds];
  [self setNeedsDisplay:YES];
}

- (NSRect)rectForTerminalRow:(NSUInteger)row snapshot:(COTTerminalSnapshot *)snapshot {
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSFont *font = [theme font];
  NSEdgeInsets insets = [theme contentInsets];
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : MAX([font ascender] - [font descender] + [theme lineSpacing], 1.0);
  CGFloat y = NSMaxY([self bounds]) - insets.top - lineHeight - (CGFloat)row * lineHeight;
  return NSMakeRect(0.0, y, [self bounds].size.width, lineHeight);
}

- (void)scheduleScreenUpdate {
  if (_screenUpdateScheduled) {
    return;
  }
  _screenUpdateScheduled = YES;
  [self performSelector:@selector(performPendingScreenUpdate) withObject:nil afterDelay:COTTerminalRepaintInterval()];
}

- (void)recordPerfUpdateWithDirtyRowCount:(NSUInteger)dirtyRowCount {
  _perfScreenUpdates += 1;
  _perfDirtyRows += dirtyRowCount;
  if (!_perfLoggingEnabled) {
    return;
  }
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (now - _perfLastLogTime >= 1.0) {
    fprintf(stderr,
            "[CocoaTerminal perf] updates=%lu draws=%lu dirtyRows=%lu\n",
            (unsigned long)_perfScreenUpdates,
            (unsigned long)_perfDrawCalls,
            (unsigned long)_perfDirtyRows);
    fflush(stderr);
    _perfScreenUpdates = 0;
    _perfDrawCalls = 0;
    _perfDirtyRows = 0;
    _perfLastLogTime = now;
  }
}

- (void)performPendingScreenUpdate {
  _screenUpdateScheduled = NO;
  COTTerminalSnapshot *snapshot = [_session currentSnapshot];
  if (snapshot == nil) {
    [_pendingDirtyRows removeAllIndexes];
    _pendingFullRedraw = NO;
    return;
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:COTTerminalViewDidUpdateScreenNotification object:self];
  if ([self isHiddenOrHasHiddenAncestor] || [self window] == nil) {
    [_pendingDirtyRows removeAllIndexes];
    _pendingFullRedraw = YES;
    return;
  }

  // The cursor's old row and its new one join the rows whose text changed.
  NSUInteger cursorRow = snapshot->viewportOffset == 0 && snapshot->cursorRow < snapshot->rows ? snapshot->cursorRow : NSNotFound;
  if (_paintedCursorRow != cursorRow) {
    if (_paintedCursorRow != NSNotFound && _paintedCursorRow < snapshot->rows) [_pendingDirtyRows addIndex:_paintedCursorRow];
    if (cursorRow != NSNotFound) [_pendingDirtyRows addIndex:cursorRow];
  }
  _paintedCursorRow = cursorRow;
  NSUInteger dirtyCount = [_pendingDirtyRows count];
  BOOL fullRedraw = _pendingFullRedraw || dirtyCount == 0 || dirtyCount > MAX((NSUInteger)1, snapshot->rows / 2);
  [self recordPerfUpdateWithDirtyRowCount:(fullRedraw ? snapshot->rows : dirtyCount)];
  if (fullRedraw) {
    _perfFullRedraws += 1;
    [self setNeedsDisplay:YES];
  } else {
    NSUInteger row = [_pendingDirtyRows firstIndex];
    while (row != NSNotFound) {
      [self setNeedsDisplayInRect:[self rectForTerminalRow:row snapshot:snapshot]];
      row = [_pendingDirtyRows indexGreaterThanIndex:row];
    }
  }
  [_pendingDirtyRows removeAllIndexes];
  _pendingFullRedraw = NO;
  [self updateInputMethodPositionWithSnapshot:snapshot];
}

- (void)updateInputMethodPosition {
  [self updateInputMethodPositionWithSnapshot:[_session currentSnapshot]];
}

// Where an input method shows what's being composed (Chinese, Japanese, Korean...): at the terminal's cursor. GNUstep's
// Windows back end commits IME text as key events but never places the composition window, so the IME put it at its
// default place, away from the text. Only while the view has the focus.
- (void)updateInputMethodPositionWithSnapshot:(COTTerminalSnapshot *)snapshot {
#if defined(_WIN32)
  NSWindow *window = [self window];
  if (snapshot == nil || window == nil || [window firstResponder] != self) {
    return;
  }
  HWND hwnd = (HWND)(intptr_t)[window windowNumber];
  HIMC context = hwnd != NULL ? ImmGetContext(hwnd) : NULL;
  if (context == NULL) {
    return;
  }
  COTTerminalTheme *theme = [[_session configuration] theme];
  NSFont *font = [theme font];
  CGFloat lineHeight = _lineHeight > 0 ? _lineHeight : [font ascender] - [font descender] + [theme lineSpacing];
  CGFloat cellWidth = _cellWidth > 0 ? _cellWidth : [@"M" sizeWithAttributes:_textAttributes].width;
  NSEdgeInsets insets = [theme contentInsets];
  // The cursor cell's top left, in the view, then the window, then the screen (GNUstep's: y up from the bottom of the
  // primary screen), then Windows' screen (y down from its top) and the window's client area.
  NSPoint topLeft = NSMakePoint(insets.left + (CGFloat)snapshot->cursorColumn * cellWidth,
                                NSMaxY([self bounds]) - insets.top - (CGFloat)snapshot->cursorRow * lineHeight);
  NSPoint inWindow = [self convertPoint:topLeft toView:nil];
  NSPoint onScreen = [window convertBaseToScreen:inWindow];
  POINT point;
  point.x = (LONG)lround(onScreen.x);
  point.y = (LONG)lround((CGFloat)GetSystemMetrics(SM_CYSCREEN) - onScreen.y);
  ScreenToClient(hwnd, &point);
  COMPOSITIONFORM composition;
  composition.dwStyle = CFS_POINT;
  composition.ptCurrentPos = point;
  ImmSetCompositionWindow(context, &composition);
  CANDIDATEFORM candidates;  // the list of choices below the line being composed
  candidates.dwIndex = 0;
  candidates.dwStyle = CFS_CANDIDATEPOS;
  candidates.ptCurrentPos.x = point.x;
  candidates.ptCurrentPos.y = point.y + (LONG)lround(lineHeight);
  ImmSetCandidateWindow(context, &candidates);
  ImmReleaseContext(hwnd, context);
#else
  (void)snapshot;
#endif
}

- (NSDictionary *)performanceSnapshot {
  return [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithUnsignedInteger:_perfScreenUpdates], @"screenUpdates",
    [NSNumber numberWithUnsignedInteger:_perfDrawCalls], @"drawCalls",
    [NSNumber numberWithUnsignedInteger:_perfDirtyRows], @"dirtyRows",
    [NSNumber numberWithUnsignedInteger:_perfFullRedraws], @"fullRedraws",
    [NSNumber numberWithDouble:(1.0 / COTTerminalRepaintInterval())], @"maxFPS",
    ([self wantsOpenGL] && !_glUnavailable && _glRenderer != NULL) ? @"opengl" : @"cairo", @"renderer",
    // How OpenGL frames reach the screen: straight into the window, or read back and drawn as an image.
    ([self wantsOpenGL] && !_glUnavailable && _glRenderer != NULL) ? (_glRendererContext != NULL ? @"window" : @"image")
                                                                   : @"none", @"glPresentation",
    nil];
}

- (void)terminalSessionDidUpdateScreen:(COTTerminalSession *)session {
  COTTerminalSnapshot *snapshot = [session currentSnapshot];
  if (snapshot == nil) {
    _pendingFullRedraw = YES;
    [self scheduleScreenUpdate];
    return;
  }
  if (snapshot->fullRedraw || snapshot->dirtyRows.empty()) {
    _pendingFullRedraw = YES;
  } else {
    for (std::size_t row = 0; row < snapshot->dirtyRows.size(); ++row) {
      if (snapshot->dirtyRows[row]) {
        [_pendingDirtyRows addIndex:(NSUInteger)row];
      }
    }
  }
  [self scheduleScreenUpdate];
}

- (void)terminalSession:(COTTerminalSession *)session didEncounterTransportError:(NSString *)message {
  (void)session; (void)message; [self setNeedsDisplay:YES];
}
- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)status {
  (void)session;
  [[NSNotificationCenter defaultCenter] postNotificationName:COTTerminalViewDidExitNotification
                                                      object:self
                                                    userInfo:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:status]
                                                                                         forKey:COTTerminalExitStatusUserInfoKey]];
  COTTerminalExitBehavior behavior = [[_session configuration] exitBehavior];
  if (behavior == COTTerminalExitBehaviorCloseOwningWindow) {
    [[self window] close];
  } else if (behavior == COTTerminalExitBehaviorTerminateApplication) {
    [NSApp terminate:nil];
  }
}

@synthesize session = _session;

@end
