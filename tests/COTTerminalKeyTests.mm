// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Keys carry the platform's keyCode. GNUstep's is the X11 keycode, which collided with the macOS key codes CocoaTerminal
// matched: "|" and "\" (X 51) sent Backspace, and Ctrl+Q / Ctrl+R / Ctrl+Y (X 24, 27, 29) zoomed instead of reaching the
// shell. Each key goes to a terminal running `dd` in raw mode, with its X11 keycode on a US layout, and the bytes the
// pty got are compared. Needs a display (run it under Xvfb); skips, passing, without one. Not on macOS, whose keyCodes
// are its own.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>
#include <unistd.h>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

static NSEvent *Key(NSString *characters, NSString *base, unsigned short keyCode, NSUInteger flags) {
  return [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil
                        characters:characters charactersIgnoringModifiers:base isARepeat:NO keyCode:keyCode];
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if defined(__APPLE__)
  std::cout << "skipped: macOS keyCodes are its own\n";
  return 0;
#endif
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
  [NSApplication sharedApplication];
  char path[] = "/tmp/cot-key-test-XXXXXX";
  int fd = mkstemp(path);
  close(fd);
  NSString *out = [NSString stringWithUTF8String:path];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  [configuration setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-c",
                                  [NSString stringWithFormat:@"stty raw -echo; exec dd bs=1 of='%@' 2>/dev/null", out], nil]];
  NSRect frame = NSMakeRect(0, 0, 400, 200);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
  CGFloat fontSize = [[[[view session] configuration] theme] fontSize];

  const NSUInteger shift = NSShiftKeyMask, ctrl = NSCommandKeyMask;  // GNUstep reports the physical Ctrl key as Command
  // X11 keycodes on a US layout: 38 a, 51 backslash/bar, 56 b, 54 c, 49 grave/asciitilde, 40 d, 26 e, 24 q, 27 r, 29 y.
  NSArray *keys = [NSArray arrayWithObjects:
    Key(@"a", @"a", 38, 0), Key(@"|", @"|", 51, shift), Key(@"b", @"b", 56, 0), Key(@"\\", @"\\", 51, 0),
    Key(@"c", @"c", 54, 0), Key(@"~", @"~", 49, shift), Key(@"d", @"d", 40, 0), Key(@"`", @"`", 49, 0), Key(@"e", @"e", 26, 0),
    Key(@"!", @"!", 10, shift), Key(@"@", @"@", 11, shift), Key(@"{", @"{", 34, shift), Key(@"}", @"}", 35, shift),
    Key(@"\x12", @"r", 27, ctrl), Key(@"\x11", @"q", 24, ctrl), Key(@"\x19", @"y", 29, ctrl), nil];
  for (NSEvent *event in keys) [view keyDown:event];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];

  NSData *got = [NSData dataWithContentsOfFile:out];
  NSData *want = [@"a|b\\c~d`e!@{}\x12\x11\x19" dataUsingEncoding:NSUTF8StringEncoding];
  std::cout << "pty got " << [got length] << " bytes: " << [[[[NSString alloc] initWithData:got encoding:NSUTF8StringEncoding] autorelease] UTF8String] << "\n";
  expect([got isEqualToData:want], "each key's own bytes reach the pty: | and \\ aren't Backspace, Ctrl+R/Q/Y are control bytes");
  expect([[[[view session] configuration] theme] fontSize] == fontSize, "Ctrl+Q / Ctrl+R / Ctrl+Y don't zoom");

  [[view session] terminate];
  unlink(path);
  [pool release];
  std::cout << "COTTerminalKeyTests passed\n";
  return 0;
}
