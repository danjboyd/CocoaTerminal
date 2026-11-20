// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Do OpenGL views work inside GNUstep windows on Windows and X11, reliably enough for a terminal view? Not a unit
// test: it opens real windows, reads what the screen really shows (GDI or the X root window, not GNUstep's own
// buffer), clicks with real input (SendInput or XTest), and prints PASS / FAIL / INFO for each check.
//
// Two ways to put OpenGL in a view are checked:
//   child:     NSOpenGLView. GNUstep's Windows and X11 backends make it a child window over the GNUstep window.
//   offscreen: an ordinary NSView that draws a frame rendered by OpenGL off-screen (a framebuffer object in a hidden
//              context) and read back. No child window; costs a readback and a blit per frame.
//
//   CocoaTerminalGLCheck [--cycles N] [--width W --height H] [--only child|offscreen|cost]
//   (Windows: put Mesa's opengl32.dll beside it for modern GL. X11: run it on a display with GLX and no compositor,
//   such as Xvfb +extension GLX; the X11 helpers are in COTGLCheckX11.cpp.)

#import <AppKit/AppKit.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#if defined(_WIN32) || !defined(__APPLE__)
#include <GL/gl.h>
extern "C" {
int COTGLScreenPixel(void *window, double x, double y, unsigned char rgb[3]);
int COTGLClick(void *window, double x, double y);
int COTGLPointVisible(void *window, double x, double y);
int COTGLSaveWindow(void *window, const char *path);
int COTGLKey(void *window, unsigned short vk);
#if defined(_WIN32)
void COTGLResources(unsigned long *gdi, unsigned long *user, unsigned long *handles, double *privateMB);
#else
void COTGLX11SetDisplay(void *display);
void COTGLX11Resources(void *owner, unsigned long *gdi, unsigned long *user, unsigned long *handles, double *privateMB);
#endif
int COTGLChildWindowCount(void *window);
void *COTGLOffscreenCreate(int width, int height, char *message, int messageLength);
void COTGLOffscreenRender(void *handle, float red, float green, float blue, int cells, unsigned char *pixels);
void COTGLOffscreenDestroy(void *handle);
}
#endif

#if !defined(_WIN32)
#import <GNUstepGUI/GSDisplayServer.h>
#endif

static int gFailures = 0;

// The native window the helpers take: the HWND on Windows (GNUstep's window number), the X window on X11.
static void *NativeWindow(NSWindow *window) {
#if defined(_WIN32)
  return (void *)(intptr_t)[window windowNumber];
#else
  return [GSCurrentServer() windowDevice:[window windowNumber]];
#endif
}

#if defined(_WIN32)
static const char *kResourceFormat = "GDI %lu->%lu, USER %lu->%lu, handles %lu->%lu";
static void Resources(NSWindow *window, unsigned long *gdi, unsigned long *user, unsigned long *handles, double *mb) {
  (void)window;
  COTGLResources(gdi, user, handles, mb);
}
#else
// X resources of this client: windows; pixmaps, GCs, pictures and the rest; all of them.
static const char *kResourceFormat = "X non-window resources %lu->%lu, X windows %lu->%lu, X resources %lu->%lu";
static void Resources(NSWindow *window, unsigned long *gdi, unsigned long *user, unsigned long *handles, double *mb) {
  COTGLX11Resources(NativeWindow(window), gdi, user, handles, mb);
}
#endif

static void Report(const char *status, const char *check, NSString *detail) {
  printf("%-5s %-34s %s\n", status, check, [detail UTF8String]);
  fflush(stdout);
  if (strcmp(status, "FAIL") == 0) gFailures++;
}

static void Spin(NSTimeInterval seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) {
    @autoreleasepool {
      NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                                             inMode:NSDefaultRunLoopMode dequeue:YES];
      if (event != nil) [NSApp sendEvent:event];
    }
  }
}

// ---- The two kinds of view.

@interface GLChildView : NSOpenGLView
@property (nonatomic) float red, green, blue;
@property (nonatomic) NSUInteger draws, mouseDowns, keyDowns;
@end

@implementation GLChildView
+ (NSOpenGLPixelFormat *)format {
  NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize, (NSOpenGLPixelFormatAttribute)24, (NSOpenGLPixelFormatAttribute)0};
  return [[[NSOpenGLPixelFormat alloc] initWithAttributes:attributes] autorelease];
}
- (instancetype)initWithFrame:(NSRect)frame red:(float)r green:(float)g blue:(float)b {
  self = [super initWithFrame:frame pixelFormat:[GLChildView format]];
  if (self) {
    _red = r;
    _green = g;
    _blue = b;
  }
  return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)rect {
  (void)rect;
  _draws++;
  [[self openGLContext] makeCurrentContext];
  NSRect bounds = [self bounds];
  glViewport(0, 0, (GLsizei)NSWidth(bounds), (GLsizei)NSHeight(bounds));
  glClearColor(_red, _green, _blue, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  [[self openGLContext] flushBuffer];
}
- (void)mouseDown:(NSEvent *)event { (void)event; _mouseDowns++; }
- (void)keyDown:(NSEvent *)event { (void)event; _keyDowns++; }
@end

@interface GLOffscreenView : NSView
@property (nonatomic) float red, green, blue;
@property (nonatomic) int cells;
@property (nonatomic) NSUInteger draws;
@property (nonatomic) double renderMs, blitMs;
@end

@implementation GLOffscreenView {
  void *_gl;
  std::vector<unsigned char> _pixels;
  int _width, _height;
}
- (instancetype)initWithFrame:(NSRect)frame red:(float)r green:(float)g blue:(float)b {
  self = [super initWithFrame:frame];
  if (self) {
    _red = r;
    _green = g;
    _blue = b;
  }
  return self;
}
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)rect {
  (void)rect;
  _draws++;
  int width = (int)NSWidth([self bounds]), height = (int)NSHeight([self bounds]);
  if (_gl == NULL || width != _width || height != _height) {
    if (_gl) COTGLOffscreenDestroy(_gl);
    char message[300];
    _gl = COTGLOffscreenCreate(width, height, message, sizeof message);
    _width = width;
    _height = height;
    _pixels.assign((size_t)width * height * 4, 0);
    if (_gl == NULL) {
      static BOOL said = NO;
      if (!said) Report("INFO", "offscreen: setup failed", [NSString stringWithUTF8String:message]);
      said = YES;
      [[NSColor redColor] set];
      NSRectFill([self bounds]);
      return;
    }
  }
  NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
  COTGLOffscreenRender(_gl, _red, _green, _blue, _cells, _pixels.data());
  NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
  // BGRA bottom-up from OpenGL; NSBitmapImageRep wants RGBA top-down. Swizzle and flip.
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
      bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
      bytesPerRow:width * 4 bitsPerPixel:32];
  unsigned char *out = [rep bitmapData];
  for (int y = 0; y < height; y++) {
    const unsigned char *src = _pixels.data() + (size_t)(height - 1 - y) * width * 4;
    unsigned char *dst = out + (size_t)y * width * 4;
    for (int x = 0; x < width; x++) {
      dst[4 * x] = src[4 * x + 2];
      dst[4 * x + 1] = src[4 * x + 1];
      dst[4 * x + 2] = src[4 * x];
      dst[4 * x + 3] = 255;
    }
  }
  [rep drawInRect:[self bounds]];
  [rep release];
  NSTimeInterval t2 = [NSDate timeIntervalSinceReferenceDate];
  _renderMs = (t1 - t0) * 1000;
  _blitMs = (t2 - t1) * 1000;
}
- (void)dealloc {
  if (_gl) COTGLOffscreenDestroy(_gl);
  [super dealloc];
}
@end

@interface SolidView : NSView
@property (nonatomic, retain) NSColor *colour;
@end
@implementation SolidView
- (void)drawRect:(NSRect)rect { (void)rect; [_colour set]; NSRectFill([self bounds]); }
- (void)dealloc { [_colour release]; [super dealloc]; }
@end

// ---- Reading the screen.

static BOOL Near(const unsigned char rgb[3], int r, int g, int b) {
  return abs(rgb[0] - r) <= 24 && abs(rgb[1] - g) <= 24 && abs(rgb[2] - b) <= 24;
}

static NSString *Hex(const unsigned char rgb[3]) {
  return [NSString stringWithFormat:@"#%02x%02x%02x", rgb[0], rgb[1], rgb[2]];
}

// What the screen shows at the centre of a view's rect (in its window), or at a given point in the window.
// GNUstep's window coordinates include the window's border; Win32's client area doesn't. The content view's origin in
// window coordinates is that border. On X11 the X window is the content area when the window manager draws the
// decorations, and the whole frame when GNUstep does.
static NSPoint ClientPoint(NSWindow *window, NSPoint base) {
  NSPoint inset = [[window contentView] frame].origin;
#if !defined(_WIN32)
  if (![GSCurrentServer() handlesWindowDecorations]) inset = NSZeroPoint;
#endif
  return NSMakePoint(base.x - inset.x, base.y - inset.y);
}
static BOOL ScreenAt(NSWindow *window, NSPoint base, unsigned char rgb[3]) {
  NSPoint p = ClientPoint(window, base);
#if !defined(_WIN32)
  // Without a compositor X can't show a covered window (Windows' PrintWindow can), so bring it to the front first.
  if (!COTGLPointVisible(NativeWindow(window), p.x, p.y)) {
    [window orderFrontRegardless];
    Spin(0.3);
  }
#endif
  return COTGLScreenPixel(NativeWindow(window), p.x, p.y, rgb);
}
static NSPoint CentreInWindow(NSView *view) {
  NSRect r = [view convertRect:[view bounds] toView:nil];
  return NSMakePoint(NSMidX(r), NSMidY(r));
}

static NSWindow *MakeWindow(NSRect frame, NSString *title) {
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSTitledWindowMask | NSResizableWindowMask | NSMiniaturizableWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  [window setTitle:title];
  [window setReleasedWhenClosed:NO];
  [window setLevel:NSFloatingWindowLevel];  // above anything else on the desktop, so the screen shows it
  SolidView *content = [[[SolidView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))] autorelease];
  content.colour = [NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:1];  // #333333
  [window setContentView:content];
  [window orderFrontRegardless];
  return window;
}

// A view of the given kind, magenta unless told otherwise.
static NSView *MakeGLView(BOOL child, NSRect frame, float r, float g, float b) {
  if (child) return [[[GLChildView alloc] initWithFrame:frame red:r green:g blue:b] autorelease];
  return [[[GLOffscreenView alloc] initWithFrame:frame red:r green:g blue:b] autorelease];
}

static void Redraw(NSWindow *window) {
  [[window contentView] setNeedsDisplay:YES];
  [window display];
  Spin(0.4);
}

// ---- The checks, run once for each kind of view.

static void RunChecks(BOOL child, int cycles) {
  const char *kind = child ? "child" : "offscreen";
  char name[64];
  unsigned char rgb[3];
  printf("\n== %s: %s\n", kind, child ? "NSOpenGLView (a child window)" : "off-screen framebuffer, read back and drawn");

  // 1. It draws, where the view is.
  NSWindow *window = MakeWindow(NSMakeRect(80, 120, 520, 360), @"GL check");
  NSView *gl = MakeGLView(child, NSMakeRect(40, 40, 300, 200), 1, 0, 1);
  [[window contentView] addSubview:gl];
  Redraw(window);
  snprintf(name, sizeof name, "%s: draws", kind);
  if (ScreenAt(window, CentreInWindow(gl), rgb) && Near(rgb, 255, 0, 255)) {
    Report("PASS", name, [NSString stringWithFormat:@"magenta at the view's centre (%@)", Hex(rgb)]);
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"expected magenta at the view's centre, screen shows %@", Hex(rgb)]);
  }
  if (child) {
    [[(GLChildView *)gl openGLContext] makeCurrentContext];
    Report("INFO", "child: renderer", [NSString stringWithFormat:@"%s / %s", glGetString(GL_RENDERER), glGetString(GL_VERSION)]);
  }
  snprintf(name, sizeof name, "%s: outside the view untouched", kind);
  if (ScreenAt(window, NSMakePoint(20, 20), rgb) && Near(rgb, 0x33, 0x33, 0x33)) {
    Report("PASS", name, Hex(rgb));
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"expected #333333 beside the view, screen shows %@", Hex(rgb)]);
  }

  // 2. A GNUstep view on top of it (added later, overlapping): a popover, a find bar, a scroll indicator.
  SolidView *overlay = [[[SolidView alloc] initWithFrame:NSMakeRect(150, 100, 80, 60)] autorelease];
  overlay.colour = [NSColor greenColor];
  [[window contentView] addSubview:overlay positioned:NSWindowAbove relativeTo:gl];
  Redraw(window);
  snprintf(name, sizeof name, "%s: a view drawn over it shows", kind);
  if (ScreenAt(window, CentreInWindow(overlay), rgb) && Near(rgb, 0, 255, 0)) {
    Report("PASS", name, [NSString stringWithFormat:@"green over the GL area (%@)", Hex(rgb)]);
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"expected the green view on top, screen shows %@", Hex(rgb)]);
  }
  [overlay removeFromSuperview];

  // 3. The window grows and the view with it.
  [gl setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  NSRect wf = [window frame];
  wf.size.width += 200;
  wf.size.height += 120;
  [window setFrame:wf display:YES];
  Redraw(window);
  if (getenv("GLCHECK_RESIZE_REDRAW")) {  // experiment: does an explicit redraw of the view itself fix it?
    [gl setNeedsDisplay:YES];
    [gl display];
    Spin(1.0);
  }
  if (getenv("GLCHECK_SAVE")) COTGLSaveWindow(NativeWindow(window), getenv("GLCHECK_SAVE"));
  NSRect inWindow = [gl convertRect:[gl bounds] toView:nil];
  snprintf(name, sizeof name, "%s: follows a resize", kind);
  BOOL farCorner = ScreenAt(window, NSMakePoint(NSMaxX(inWindow) - 6, NSMaxY(inWindow) - 6), rgb) && Near(rgb, 255, 0, 255);
  unsigned char farRGB[3] = {rgb[0], rgb[1], rgb[2]};
  BOOL beyond = ScreenAt(window, NSMakePoint(NSMaxX(inWindow) + 6, NSMaxY(inWindow) + 6), rgb) && Near(rgb, 0x33, 0x33, 0x33);
  if (farCorner && beyond) {
    Report("PASS", name, [NSString stringWithFormat:@"view now %.0fx%.0f, its far corner magenta", NSWidth(inWindow), NSHeight(inWindow)]);
  } else {
    unsigned char mid[3] = {0, 0, 0}, quarter[3] = {0, 0, 0};
    ScreenAt(window, NSMakePoint(NSMidX(inWindow), NSMidY(inWindow)), mid);
    ScreenAt(window, NSMakePoint(NSMinX(inWindow) + NSWidth(inWindow) * 0.75, NSMinY(inWindow) + NSHeight(inWindow) * 0.75), quarter);
    Report("FAIL", name, [NSString stringWithFormat:@"view %@ in a %.0fx%.0f content view: far corner %@ (want magenta), "
                          @"just beyond %@ (want #333333), centre %@, 3/4 point %@", NSStringFromRect(inWindow),
                          NSWidth([[window contentView] frame]), NSHeight([[window contentView] frame]), Hex(farRGB), Hex(rgb),
                          Hex(mid), Hex(quarter)]);
  }
  [gl setAutoresizingMask:NSViewNotSizable];

  // 4. A parent moves; the view's own frame doesn't change (a split view moving its right pane, a tab bar appearing).
  NSPoint before = CentreInWindow(gl);
  NSView *container = [[[NSView alloc] initWithFrame:[[window contentView] bounds]] autorelease];
  [gl retain];
  [gl removeFromSuperview];
  [container addSubview:gl];
  [gl release];
  [[window contentView] addSubview:container];
  Redraw(window);
  [container setFrameOrigin:NSMakePoint(120, 60)];
  Redraw(window);
  NSPoint after = CentreInWindow(gl);
  snprintf(name, sizeof name, "%s: follows a parent's move", kind);
  BOOL atNew = ScreenAt(window, after, rgb) && Near(rgb, 255, 0, 255);
  unsigned char newRGB[3] = {rgb[0], rgb[1], rgb[2]};
  NSPoint vacated = NSMakePoint(before.x - 130, before.y - 70);  // inside the old rect, outside the new one
  NSRect newRect = [gl convertRect:[gl bounds] toView:nil];
  BOOL oldClear = NSPointInRect(vacated, newRect) || (ScreenAt(window, vacated, rgb) && Near(rgb, 0x33, 0x33, 0x33));
  if (atNew && oldClear) {
    Report("PASS", name, @"drawn at the new place, old place cleared");
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"new place shows %@ (want magenta); old place shows %@ (want #333333)",
                          Hex(newRGB), Hex(rgb)]);
  }

  // 5. Hidden, and a hidden parent.
  [gl setHidden:YES];
  Redraw(window);
  snprintf(name, sizeof name, "%s: hides", kind);
  if (ScreenAt(window, CentreInWindow(gl), rgb) && !Near(rgb, 255, 0, 255)) {
    Report("PASS", name, Hex(rgb));
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"hidden view still on screen (%@)", Hex(rgb)]);
  }
  [gl setHidden:NO];
  [container setHidden:YES];
  Redraw(window);
  snprintf(name, sizeof name, "%s: hides with its parent", kind);
  if (ScreenAt(window, CentreInWindow(gl), rgb) && !Near(rgb, 255, 0, 255)) {
    Report("PASS", name, Hex(rgb));
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"view in a hidden parent still on screen (%@)", Hex(rgb)]);
  }
  [container setHidden:NO];
  Redraw(window);

  // 6. Removed, then added back.
  NSPoint spot = CentreInWindow(gl);
  [gl retain];
  [gl removeFromSuperview];
  Redraw(window);
  snprintf(name, sizeof name, "%s: goes when removed", kind);
  if (ScreenAt(window, spot, rgb) && !Near(rgb, 255, 0, 255)) {
    Report("PASS", name, Hex(rgb));
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"removed view still on screen (%@)", Hex(rgb)]);
  }
  [container addSubview:gl];
  [gl release];
  Redraw(window);
  snprintf(name, sizeof name, "%s: draws again when re-added", kind);
  if (ScreenAt(window, CentreInWindow(gl), rgb) && Near(rgb, 255, 0, 255)) {
    Report("PASS", name, Hex(rgb));
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"re-added view shows %@", Hex(rgb)]);
  }

  // 7. Clipped by a scroll view: scrolled half out of sight, it mustn't draw over the scroller or outside the clip. In
  // a window of its own, so no other GL view is under the points it reads.
  NSWindow *scrollWindow = MakeWindow(NSMakeRect(80, 120, 300, 260), @"GL check scroll");
  NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(40, 40, 200, 150)] autorelease];
  [scroll setHasVerticalScroller:YES];
  NSView *document = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 180, 600)] autorelease];
  NSView *scrolled = MakeGLView(child, NSMakeRect(0, 200, 180, 200), 0, 1, 1);  // cyan
  [document addSubview:scrolled];
  [scroll setDocumentView:document];
  [[scrollWindow contentView] addSubview:scroll];
  Redraw(scrollWindow);
  // Scrolled so the visible area starts halfway up the cyan view: its lower half (or upper, if the document is
  // flipped) is now outside the scroll view.
  [[scroll contentView] scrollToPoint:NSMakePoint(0, 300)];
  [scroll reflectScrolledClipView:[scroll contentView]];
  Redraw(scrollWindow);
  NSRect scrollInWindow = [scroll convertRect:[scroll bounds] toView:nil];
  // Just outside the scroll view, above and below it: neither may be cyan.
  NSPoint above = NSMakePoint(NSMidX(scrollInWindow) - 10, NSMaxY(scrollInWindow) + 8);
  NSPoint below = NSMakePoint(NSMidX(scrollInWindow) - 10, NSMinY(scrollInWindow) - 8);
  snprintf(name, sizeof name, "%s: clipped by a scroll view", kind);
  BOOL leaked = ScreenAt(scrollWindow, above, rgb) && Near(rgb, 0, 255, 255);
  unsigned char aboveRGB[3] = {rgb[0], rgb[1], rgb[2]};
  leaked = (ScreenAt(scrollWindow, below, rgb) && Near(rgb, 0, 255, 255)) || leaked;
  if (Near(rgb, 0, 255, 255)) memcpy(aboveRGB, rgb, 3);
  NSRect visible = [scrolled convertRect:[scrolled visibleRect] toView:nil];
  BOOL shows = !NSIsEmptyRect(visible) && ScreenAt(scrollWindow, NSMakePoint(NSMidX(visible), NSMidY(visible)), rgb) &&
               Near(rgb, 0, 255, 255);
  if (!leaked && shows) {
    Report("PASS", name, @"visible part drawn, nothing outside the clip");
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"visible part %@ (want cyan); just outside the scroll view %@ (want not cyan)",
                          Hex(rgb), Hex(aboveRGB)]);
  }
  [scrollWindow close];
  [scrollWindow release];
  Redraw(window);

  // 8. Two in one window, and one in a second window.
  NSView *second = MakeGLView(child, NSMakeRect(560, 10, 120, 40), 1, 1, 0);  // yellow, clear of the first
  [[window contentView] addSubview:second];
  NSWindow *other = MakeWindow(NSMakeRect(700, 120, 300, 220), @"GL check 2");
  NSView *third = MakeGLView(child, NSMakeRect(30, 30, 200, 140), 0, 0, 1);  // blue
  [[other contentView] addSubview:third];
  Redraw(window);
  Redraw(other);
  unsigned char a[3], b[3], c[3];
  ScreenAt(window, CentreInWindow(gl), a);
  ScreenAt(window, CentreInWindow(second), b);
  ScreenAt(other, CentreInWindow(third), c);
  snprintf(name, sizeof name, "%s: several at once", kind);
  if (Near(a, 255, 0, 255) && Near(b, 255, 255, 0) && Near(c, 0, 0, 255)) {
    Report("PASS", name, @"magenta, yellow and blue each in place");
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"want magenta/yellow/blue, got %@ %@ %@", Hex(a), Hex(b), Hex(c)]);
  }
  [second removeFromSuperview];
  [other close];
  [other release];

  // 9. Minimised and restored.
  [window miniaturize:nil];
  Spin(0.8);
  [window deminiaturize:nil];
  Spin(0.8);
  Redraw(window);
  snprintf(name, sizeof name, "%s: survives minimise/restore", kind);
  if (ScreenAt(window, CentreInWindow(gl), rgb) && Near(rgb, 255, 0, 255)) {
    Report("PASS", name, Hex(rgb));
  } else {
    Report("FAIL", name, [NSString stringWithFormat:@"after restore the view shows %@", Hex(rgb)]);
  }

  // 10. Reading the window back, as CocoaTerminal's PNG capture does.
  NSView *content = [window contentView];
  [content lockFocus];
  NSBitmapImageRep *shown = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:[content bounds]] autorelease];
  [content unlockFocus];
  NSPoint centre = [content convertPoint:CentreInWindow(gl) fromView:nil];
  NSColor *readBack = [[shown colorAtX:(NSInteger)centre.x y:(NSInteger)(NSHeight([content bounds]) - centre.y)]
                       colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  snprintf(name, sizeof name, "%s: in a window readback", kind);
  BOOL magenta = readBack && [readBack redComponent] > 0.9 && [readBack greenComponent] < 0.1 && [readBack blueComponent] > 0.9;
  Report(magenta ? "PASS" : "FAIL", name,
         [NSString stringWithFormat:@"initWithFocusedViewRect: at the view's centre gives %.2f %.2f %.2f",
          [readBack redComponent], [readBack greenComponent], [readBack blueComponent]]);

  // 11. Real input: a click on it, then a key while it's first responder.
  [window makeKeyAndOrderFront:nil];
  Spin(0.3);
  NSPoint visibleAt = ClientPoint(window, CentreInWindow(gl));
  if (child && !COTGLPointVisible(NativeWindow(window), visibleAt.x, visibleAt.y)) {
    Report("SKIP", "child: real click and key", @"another window covers this one on screen, so real input can't reach it");
  } else if (child) {
    GLChildView *v = (GLChildView *)gl;
    NSUInteger clicks = v.mouseDowns;
    NSPoint p = ClientPoint(window, CentreInWindow(gl));
    COTGLClick(NativeWindow(window), p.x, p.y);
    Spin(0.6);
    snprintf(name, sizeof name, "%s: gets a real click", kind);
    Report(v.mouseDowns > clicks ? "PASS" : "FAIL", name,
           [NSString stringWithFormat:@"mouseDown: %lu time(s)", (unsigned long)(v.mouseDowns - clicks)]);
    [window makeFirstResponder:v];
    NSUInteger keys = v.keyDowns;
    COTGLKey(NativeWindow(window), 'A');
    Spin(0.6);
    snprintf(name, sizeof name, "%s: gets a real key", kind);
    Report(v.keyDowns > keys ? "PASS" : "FAIL", name,
           [NSString stringWithFormat:@"keyDown: %lu time(s)", (unsigned long)(v.keyDowns - keys)]);
    Report("INFO", "child: child windows", [NSString stringWithFormat:@"%d child window(s) in the GL window",
                                            COTGLChildWindowCount(NativeWindow(window))]);
  }

  // 12. Leaks: create, show, draw and destroy it many times.
  unsigned long gdi0, user0, handles0, gdi1, user1, handles1;
  double mem0, mem1;
  for (int warm = 0; warm < 5; warm++) {
    @autoreleasepool {
      NSView *v = MakeGLView(child, NSMakeRect(20, 20, 120, 80), 0.5, 0.5, 0.5);
      [[window contentView] addSubview:v];
      [window display];
      [v removeFromSuperview];
    }
  }
  Spin(0.3);
  Resources(window, &gdi0, &user0, &handles0, &mem0);
  NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
  for (int i = 0; i < cycles; i++) {
    @autoreleasepool {
      NSView *v = MakeGLView(child, NSMakeRect(20, 20, 120, 80), 0.5, 0.5, 0.5);
      [[window contentView] addSubview:v];
      [window display];
      [v removeFromSuperview];
    }
    if (i % 50 == 0) Spin(0.01);
  }
  Spin(0.5);
  Resources(window, &gdi1, &user1, &handles1, &mem1);
  snprintf(name, sizeof name, "%s: %d create/destroy cycles", kind, cycles);
  BOOL steady = gdi1 <= gdi0 + 10 && user1 <= user0 + 10 && handles1 <= handles0 + 20 && mem1 - mem0 < 50;
  Report(steady ? "PASS" : "FAIL", name,
         [NSString stringWithFormat:@"%@, private %.0f->%.0f MB, %.1f ms/cycle",
          [NSString stringWithFormat:[NSString stringWithUTF8String:kResourceFormat], gdi0, gdi1, user0, user1, handles0, handles1],
          mem0, mem1, ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000 / cycles]);

  [window close];
  [window release];
}

// The off-screen path's cost per frame at terminal-window sizes: render, read back, and draw into the view.
static void MeasureOffscreen(int width, int height) {
  NSWindow *window = MakeWindow(NSMakeRect(40, 40, width, height), @"GL offscreen cost");
  GLOffscreenView *view = [[[GLOffscreenView alloc] initWithFrame:NSMakeRect(0, 0, width, height) red:0.1 green:0.1 blue:0.1] autorelease];
  view.cells = 160;
  [[window contentView] addSubview:view];
  Redraw(window);
  double render = 0, blit = 0, total = 0;
  const int frames = 30;
  for (int i = 0; i < frames; i++) {
    @autoreleasepool {
      NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
      [view display];
      total += ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000;
      render += view.renderMs;
      blit += view.blitMs;
    }
  }
  Report("INFO", "offscreen: cost per frame",
         [NSString stringWithFormat:@"%dx%d: render+readback %.1f ms, swizzle+draw %.1f ms, whole display %.1f ms",
          width, height, render / frames, blit / frames, total / frames]);
  [window close];
  [window release];
}

@interface CheckDelegate : NSObject
@property (nonatomic) int cycles, width, height;
@property (nonatomic, copy) NSString *only;
@end
@implementation CheckDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return NO; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  @try {
    if (_only == nil || [_only isEqualToString:@"child"]) RunChecks(YES, _cycles);
    if (_only == nil || [_only isEqualToString:@"offscreen"]) RunChecks(NO, _cycles);
    if (_only == nil || [_only isEqualToString:@"offscreen"] || [_only isEqualToString:@"cost"]) MeasureOffscreen(_width, _height);
  } @catch (NSException *e) {
    Report("FAIL", "exception", [NSString stringWithFormat:@"%@: %@", [e name], [e reason]]);
  }
  printf("\n%d failure(s)\n", gFailures);
  fflush(stdout);
  exit(gFailures ? 1 : 0);
}
@end

int main(int argc, char **argv) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  [[NSUserDefaults standardUserDefaults] setObject:@"NSWindows95InterfaceStyle" forKey:@"NSMenuInterfaceStyle"];
  CheckDelegate *delegate = [[CheckDelegate alloc] init];
  delegate.cycles = 300;
  delegate.width = 1200;
  delegate.height = 720;
  for (int i = 1; i + 1 < argc; i += 2) {
    std::string flag = argv[i];
    if (flag == "--cycles") delegate.cycles = atoi(argv[i + 1]);
    else if (flag == "--width") delegate.width = atoi(argv[i + 1]);
    else if (flag == "--height") delegate.height = atoi(argv[i + 1]);
    else if (flag == "--only") delegate.only = [NSString stringWithUTF8String:argv[i + 1]];
  }
  NSApplication *app = [NSApplication sharedApplication];
#if !defined(_WIN32)
  COTGLX11SetDisplay([GSCurrentServer() serverDevice]);
#endif
  [app setDelegate:delegate];
  [app run];
  [pool drain];
  return 0;
}
