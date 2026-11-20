// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// Shell integration through a real shell (and, on Windows, through ConPTY, which has to pass OSC 133 on): a script
// marks two commands as a shell's prompt would. The session reports each finished command to its delegate with its
// command line, output and exit status, lists the prompts, and the view jumps between them. Needs a display; skips
// without.

#import <CocoaTerminal/CocoaTerminal.h>

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

static void Spin(NSTimeInterval seconds) {
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

@interface CommandRecorder : NSObject <COTTerminalDelegate> {
@public
  NSMutableArray *commands;
  id<COTTerminalDelegate> view;  // the view stays the session's delegate for everything else
}
@end

@implementation CommandRecorder
- (void)terminalSession:(COTTerminalSession *)session didFinishCommand:(NSDictionary *)command {
  (void)session;
  [commands addObject:command];
}
@end

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
#if !defined(__APPLE__) && !defined(_WIN32)
  if (getenv("DISPLAY") == NULL) {
    std::cout << "skipped: no DISPLAY\n";
    return 0;
  }
#endif
  [NSApplication sharedApplication];
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  [configuration setScrollbackLineLimit:1000];
  // Command 1: "echo hi", output "hi", status 0. Command 2: "seq", 60 lines of output, status 3. Then a prompt.
  NSString *script =
      @"M() { printf '\\033]133;%s\\007' \"$1\"; }; "
       "M A; printf '$ '; M B; printf 'echo hi\\r\\n'; M C; printf 'hi\\r\\n'; M 'D;0'; "
       "M A; printf '$ '; M B; printf 'seq\\r\\n'; M C; i=1; while [ $i -le 60 ]; do printf 'n%s\\r\\n' $i; i=$((i+1)); done; M 'D;3'; "
       "M A; printf '$ '; M B; printf 'DONE'; exec sleep 30";
#if defined(_WIN32)
  NSString *shell = @"C:\\msys64\\usr\\bin\\sh.exe";  // MSYS2's, as the bench uses
#else
  NSString *shell = @"/bin/sh";
#endif
  if (getenv("COT_SHELL_TEST_SHELL")) shell = [NSString stringWithUTF8String:getenv("COT_SHELL_TEST_SHELL")];
  [configuration setShellCommand:[NSArray arrayWithObjects:shell, @"-c", script, nil]];
  NSRect frame = NSMakeRect(0, 0, 640, 240);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setContentView:view];
  [window orderFrontRegardless];
  COTTerminalSession *session = [view session];
  CommandRecorder *recorder = [[CommandRecorder alloc] init];
  recorder->commands = [[NSMutableArray alloc] init];
  [[NSNotificationCenter defaultCenter] addObserverForName:COTTerminalSessionCommandDidFinishNotification
                                                    object:session
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                  [recorder terminalSession:session didFinishCommand:[note userInfo]];
                                                }];
  NSError *error = nil;
  expect([view startTerminalWithError:&error], "terminal should start");
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
  while ([deadline timeIntervalSinceNow] > 0 && !AnyLineHasPrefix(session, @"$ DONE")) Spin(0.05);
  expect(AnyLineHasPrefix(session, @"$ DONE"), "the output arrives");
  Spin(0.3);

  NSArray *commands = recorder->commands;
  std::cout << "finished commands reported: " << [commands count] << "\n";
  expect([commands count] == 2, "both commands are reported as they finish (the marks got through)");
  NSDictionary *first = [commands objectAtIndex:0];
  expect([[first objectForKey:COTTerminalCommandTextKey] isEqualToString:@"echo hi"], "the first command line");
  expect([[first objectForKey:COTTerminalCommandOutputKey] isEqualToString:@"hi"], "its output");
  expect([[first objectForKey:COTTerminalCommandExitStatusKey] intValue] == 0, "its status");
  NSDictionary *second = [session lastFinishedCommand];
  NSString *output = [second objectForKey:COTTerminalCommandOutputKey];
  expect([[second objectForKey:COTTerminalCommandTextKey] isEqualToString:@"seq"], "the last command, from the session");
  expect([output hasPrefix:@"n1\nn2\n"] && [output hasSuffix:@"\nn60"] &&
             [[output componentsSeparatedByString:@"\n"] count] == 60,
         "its 60 lines of output, though most are in the scrollback");
  expect([[second objectForKey:COTTerminalCommandExitStatusKey] intValue] == 3, "its status 3");

  NSArray *prompts = [session promptLines];
  expect([prompts count] == 3, "three prompts");
  // From the live screen, up to the second prompt ("$ seq"), then the first, then no further; down again.
  expect([view scrollToPreviousPrompt], "up to the previous prompt");
  Spin(0.2);
  expect([[[session visibleLines] objectAtIndex:0] hasPrefix:@"$ seq"], "the seq prompt is at the top");
  expect([view scrollToPreviousPrompt], "up again");
  Spin(0.2);
  expect([[[session visibleLines] objectAtIndex:0] hasPrefix:@"$ echo hi"], "the first prompt is at the top");
  expect(![view scrollToPreviousPrompt], "no prompt above the first");
  expect([view scrollToNextPrompt], "down to the next");
  Spin(0.2);
  expect([[[session visibleLines] objectAtIndex:0] hasPrefix:@"$ seq"], "the seq prompt again");
  expect([view scrollToNextPrompt], "down to the last prompt, on the live screen");
  Spin(0.2);
  expect([view scrollToNextPrompt] || [session viewportOffset] == 0, "and past it, the live screen");
  Spin(0.2);
  expect([session viewportOffset] == 0, "back at the live screen");

  [session terminate];
  std::cout << "COTShellIntegrationTests passed\n";
  [pool release];
  return 0;
}
