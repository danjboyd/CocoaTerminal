// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Which renderer draws. The default is Automatic: OpenGL only where it can draw straight into the window, Cairo
// otherwise (drawn through an image, OpenGL is slower than Cairo on plain text). With the direct path ruled out
// (COCOATERMINAL_GL_PRESENT=image), Automatic must draw with Cairo; COCOATERMINAL_RENDERER=cairo too. Needs a display;
// skips without one.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

static void SetEnv(const char *name, const char *value) {
#if defined(_WIN32)
  _putenv_s(name, value);
#else
  setenv(name, value, 1);
#endif
}

// What a view with this configuration draws with, once it has drawn.
static NSString *RendererFor(COTTerminalConfiguration *configuration) {
  NSRect frame = NSMakeRect(0, 0, 300, 100);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];
  [window display];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
  NSString *renderer = [[[[view performanceSnapshot] objectForKey:@"renderer"] retain] autorelease];
  [window close];
  [view release];
  return renderer;
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if !defined(__APPLE__) && !defined(_WIN32)
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
#endif
  expect([[COTTerminalConfiguration defaultConfiguration] renderer] == COTTerminalRendererAutomatic,
         "the default renderer is Automatic");

  // Rule out the direct path before any view looks (the view decides once per process).
  SetEnv("COCOATERMINAL_GL_PRESENT", "image");
  [NSApplication sharedApplication];
  COTTerminalConfiguration *automatic = [COTTerminalConfiguration defaultConfiguration];
  NSString *drawn = RendererFor(automatic);
  std::cout << "Automatic without the direct path draws with: " << [drawn UTF8String] << "\n";
  expect([drawn isEqualToString:@"cairo"], "Automatic draws with Cairo when OpenGL can't draw straight to the window");

  COTTerminalConfiguration *cairo = [COTTerminalConfiguration defaultConfiguration];
  [cairo setRenderer:COTTerminalRendererOpenGL];
  SetEnv("COCOATERMINAL_RENDERER", "cairo");
  expect([RendererFor(cairo) isEqualToString:@"cairo"], "COCOATERMINAL_RENDERER=cairo overrides an OpenGL configuration");

  COTTerminalConfiguration *copy = [[automatic copy] autorelease];
  expect([copy renderer] == COTTerminalRendererAutomatic, "a copy keeps Automatic");

  [pool release];
  std::cout << "COTRendererChoiceTests passed\n";
  return 0;
}
