// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << message << "\n";
    std::exit(1);
  }
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  COTTerminalTheme *theme = [configuration theme];

  expect([[theme name] isEqualToString:@"Alacritty Inspired Dark"], "unexpected default theme name");
  expect([[theme fontFamily] isEqualToString:@"Intel One Mono"], "unexpected default font family");
  expect([theme fontSize] == 13.0, "unexpected default font size");
  expect([theme cursorStyle] == COTTerminalCursorStyleBlock, "unexpected default cursor style");
  expect([[configuration terminalType] isEqualToString:@"xterm-256color"], "unexpected default terminal type");
  expect([configuration exitBehavior] == COTTerminalExitBehaviorKeepOpen, "unexpected default exit behavior");
  expect([[[configuration environment] objectForKey:@"TERM"] isEqualToString:@"xterm-256color"], "TERM should default to xterm-256color");
  expect([[[configuration environment] objectForKey:@"COLORTERM"] isEqualToString:@"truecolor"], "COLORTERM should default to truecolor");
  expect([theme backgroundColor] == [configuration backgroundColor], "background compatibility accessor is not theme-backed");
  expect([theme foregroundColor] == [configuration foregroundColor], "foreground compatibility accessor is not theme-backed");

  NSColor *customBackground = [NSColor colorWithCalibratedRed:0.1 green:0.2 blue:0.3 alpha:1.0];
  [configuration setBackgroundColor:customBackground];
  expect([[configuration theme] backgroundColor] == customBackground, "background setter did not update theme");

  COTTerminalConfiguration *copy = [configuration copy];
  expect([copy theme] != [configuration theme], "configuration copy should copy theme object");
  expect([[[copy theme] name] isEqualToString:[[configuration theme] name]], "copied theme did not preserve name");
  expect([copy exitBehavior] == [configuration exitBehavior], "copied configuration did not preserve exit behavior");
  [copy release];

  [pool drain];
  return 0;
}
