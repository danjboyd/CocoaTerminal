// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Typing with a keyboard layout that has dead keys and AltGr, through GNUstep's Windows back end: the view must send
// the terminal what the layout produces. Windows only (it posts key messages to the view's window with the US
// International layout loaded on this thread, so the window needn't be in front); skips elsewhere.
//   ' then e  -> é        (a dead key, then a letter)
//   ' then space -> '     (a dead key on its own)
//   AltGr+q  -> ä         (US International's AltGr layer)

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#endif

static int failures = 0;
static void check(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    failures++;
  }
}

// The view, recording the text it sends the terminal: what -keyDown: gets as characters, or -insertText: as text.
@interface RecordingView : COTTerminalView {
@public
  NSMutableString *typed;
}
@end

@implementation RecordingView
- (void)keyDown:(NSEvent *)event {
  if (getenv("COT_KEY_TEST_DEBUG")) {
    NSString *c = [event characters] ?: @"";
    std::cerr << "keyDown chars=\"" << [c UTF8String] << "\" (" << [c length] << ")\n";
  }
  [typed appendString:[event characters] ?: @""];
  [super keyDown:event];
}
@end

static void Spin(NSTimeInterval seconds) {
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// What's typed at cmd's last prompt: the text after the ">" of the last line that starts with one, trailing spaces
// dropped; nil before the first prompt.
static NSString *PromptLine(COTTerminalSession *session) {
  NSString *found = nil;
  for (NSString *line in [session visibleLines]) {
    if ([line hasPrefix:@">"]) found = line;
  }
  if (found == nil) return nil;
  NSString *typed = [found substringFromIndex:1];
  NSUInteger end = [typed length];
  while (end > 0 && [typed characterAtIndex:end - 1] == ' ') end--;
  return [typed substringToIndex:end];
}

#if defined(_WIN32)
// The key events GNUstep made from the messages, handed straight to the view: a test run in the background has no
// key window for NSApp to send them to.
static void Deliver(NSView *view) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.15];
  for (;;) {
    NSEvent *event = [NSApp nextEventMatchingMask:NSKeyDownMask | NSKeyUpMask untilDate:until inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    if (event == nil) break;
    if ([event type] == NSKeyDown) [view keyDown:event];
  }
}

static void Press(NSView *view, HWND window, HKL layout, UINT vk, bool altGr) {
  UINT scan = MapVirtualKeyExW(vk, MAPVK_VK_TO_VSC, layout);
  BYTE state[256];
  GetKeyboardState(state);
  if (altGr) {
    state[VK_CONTROL] = state[VK_LCONTROL] = 0x80;
    state[VK_MENU] = state[VK_RMENU] = 0x80;
    SetKeyboardState(state);
  }
  PostMessageW(window, WM_KEYDOWN, vk, (LPARAM)(1 | (scan << 16)));
  PostMessageW(window, WM_KEYUP, vk, (LPARAM)(1 | (scan << 16) | (1u << 30) | (1u << 31)));
  Deliver(view);
  if (altGr) {
    GetKeyboardState(state);
    state[VK_CONTROL] = state[VK_LCONTROL] = 0;
    state[VK_MENU] = state[VK_RMENU] = 0;
    SetKeyboardState(state);
  }
}
#endif

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if !defined(_WIN32)
  std::cout << "skipped: Windows only\n";
  [pool release];
  return 0;
#else
  HKL layout = LoadKeyboardLayoutW(L"00020409", KLF_ACTIVATE);  // United States-International
  if (layout == NULL || ActivateKeyboardLayout(layout, 0) == NULL) {
    std::cout << "skipped: the US International layout can't be loaded\n";
    return 0;
  }
  [NSApplication sharedApplication];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  // cmd echoes what it's typed at its prompt (">"), so the screen shows what the view sent.
  [configuration setShellCommand:[NSArray arrayWithObjects:@"cmd.exe", @"/d", @"/k", @"prompt $G", nil]];
  NSRect frame = NSMakeRect(0, 0, 400, 120);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSTitledWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  RecordingView *view = [[RecordingView alloc] initWithFrame:frame configuration:configuration];
  view->typed = [[NSMutableString alloc] init];
  [window setContentView:view];
  [window orderFrontRegardless];
  [window makeKeyWindow];
  [window makeFirstResponder:view];
  Spin(0.5);
  HWND hwnd = (HWND)(intptr_t)[window windowNumber];

  struct Case {
    const char *name;
    UINT keys[2];
    bool altGr;
    const char *expected;  // UTF-8
  } cases[] = {
      {"' then e gives é", {VK_OEM_7, 'E'}, false, "\xc3\xa9"},
      {"' then space gives '", {VK_OEM_7, VK_SPACE}, false, "'"},
      {"AltGr+q gives ä", {'Q', 0}, true, "\xc3\xa4"},
  };
  COTTerminalSession *session = [view session];
  NSError *error = nil;
  if (![view startTerminalWithError:&error]) {
    std::cerr << "FAIL: the terminal should start\n";
    return 1;
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while ([deadline timeIntervalSinceNow] > 0 && ![[PromptLine(session) ?: @"x" stringByTrimmingCharactersInSet:
                                                    [NSCharacterSet whitespaceCharacterSet]] isEqualToString:@""])
    Spin(0.05);
  // GNUstep's Windows back end makes its own key text with ToUnicodeEx after Windows' TranslateMessage has already
  // used the dead key: the accent comes twice and the letter alone ("''e"). That needs the back end fixed (a carried
  // patch); until it is, the dead-key cases are reported, not failed, unless COT_REQUIRE_DEAD_KEYS is set.
  BOOL requireDeadKeys = getenv("COT_REQUIRE_DEAD_KEYS") != NULL;
  for (const Case &c : cases) {
    [view->typed setString:@""];
    for (UINT key : c.keys) {
      if (key != 0) Press(view, hwnd, layout, key, c.altGr);
    }
    Spin(0.3);
    std::string delivered([view->typed UTF8String] ?: "");
    std::string shown([PromptLine(session) UTF8String] ?: "");
    std::cout << c.name << ": GNUstep delivered \"" << delivered << "\", the terminal got \"" << shown << "\"\n";
    bool deadKeyCase = c.keys[1] != 0;
    if (deadKeyCase && delivered.rfind("''", 0) == 0 && !requireDeadKeys) {
      std::cout << "  (GNUstep's Windows back end mangles dead keys: not checked; COT_REQUIRE_DEAD_KEYS=1 to check)\n";
    } else {
      check(shown == c.expected, c.name);
    }
    [session sendInput:[@"\r" dataUsingEncoding:NSUTF8StringEncoding]];  // cmd runs it and shows a new prompt
    Spin(0.4);
  }

  [[view session] terminate];
  [pool release];
  if (failures) return 1;
  std::cout << "COTKeyboardLayoutTests passed\n";
  return 0;
#endif
}
