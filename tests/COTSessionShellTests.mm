// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

// A session on a real shell, through the platform's terminal (forkpty on Unix, ConPTY on Windows):
// 1. A one-shot command's output reaches the grid, and its exit status reaches the delegate once, after the output.
// 2. An interactive shell echoes what's typed and runs it; the window size it sees follows a resize; terminate ends it
//    without an exit callback.
// 3. A command that can't start fails at -startWithError: with a message instead of hanging.

#import <CocoaTerminal/CocoaTerminal.h>

#include <cstdlib>
#include <iostream>

static void expect(BOOL condition, const char *message) {
  if (!condition) {
    std::cerr << message << "\n";
    std::exit(1);
  }
}

@interface COTExitRecorder : NSObject <COTTerminalDelegate>
@property(nonatomic, assign) int exits;
@property(nonatomic, assign) int status;
@property(nonatomic, assign) BOOL markerSeenAtExit;
@end
@implementation COTExitRecorder
@synthesize exits, status, markerSeenAtExit;
- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)value {
  exits++;
  status = value;
  markerSeenAtExit = [[[session visibleLines] componentsJoinedByString:@"\n"] rangeOfString:@"COT_ONESHOT"].location != NSNotFound;
}
@end

static BOOL linesContain(COTTerminalSession *session, NSString *needle) {
  return [[[session visibleLines] componentsJoinedByString:@"\n"] rangeOfString:needle].location != NSNotFound;
}

static BOOL runUntil(NSTimeInterval seconds, BOOL (^done)(void)) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) {
    if (done()) {
      return YES;
    }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
  return done();
}

static COTTerminalConfiguration *configurationWithCommand(NSArray *command) {
  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  [configuration setShellCommand:command];
  return configuration;
}

static void dumpLines(COTTerminalSession *session) {
  for (NSString *line in [session visibleLines]) {
    std::cerr << "| " << [line UTF8String] << "\n";
  }
}

int main() {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  // 1. One-shot output and exit status.
  {
#if defined(_WIN32)
    NSArray *command = [NSArray arrayWithObjects:@"cmd.exe", @"/d", @"/c", @"echo COT_ONESHOT& exit /b 3", nil];
    int expectedStatus = 3;
#else
    NSArray *command = [NSArray arrayWithObjects:@"/bin/sh", @"-c", @"printf 'COT_ONESHOT\\n'; exit 3", nil];
    int expectedStatus = 3 << 8;  // a wait status
#endif
    COTExitRecorder *recorder = [[COTExitRecorder alloc] init];
    COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:configurationWithCommand(command)];
    [session setDelegate:recorder];
    NSError *error = nil;
    expect([session startWithError:&error], "a one-shot shell should start");
    BOOL exited = runUntil(10.0, ^BOOL {
      [session poll];
      return [recorder exits] > 0;
    });
    if (!exited) dumpLines(session);
    expect(exited, "the one-shot shell's exit should reach the delegate");
    expect([recorder markerSeenAtExit], "the shell's output should be on screen by the time its exit arrives");
    if ([recorder status] != expectedStatus) std::cerr << "status " << [recorder status] << "\n";
    expect([recorder status] == expectedStatus, "the exit status should be the shell's");
    expect(![session isRunning], "an exited session isn't running");
    runUntil(0.3, ^BOOL { return NO; });
    expect([recorder exits] == 1, "the exit should be delivered once");
    [session setDelegate:nil];
    [session release];
    [recorder release];
  }

  // 2. Interactive: typing, resize, terminate.
  {
#if defined(_WIN32)
    NSArray *command = [NSArray arrayWithObjects:@"cmd.exe", @"/d", @"/q", @"/k", @"prompt $G", nil];
    NSString *typed = @"echo COT_TYPED_%COMSPEC:~0,0%OK\r";  // the expansion only happens if cmd runs it
    NSString *ran = @"COT_TYPED_OK";
    NSString *sizeQuery = @"mode con\r";
    NSString *sizeShown = @"Columns:        100";
#else
    NSArray *command = [NSArray arrayWithObjects:@"/bin/sh", nil];
    NSString *typed = @"echo COT_TYPED_$((40+2))\r";
    NSString *ran = @"COT_TYPED_42";
    NSString *sizeQuery = @"stty size\r";
    NSString *sizeShown = @"30 100";
#endif
    COTExitRecorder *recorder = [[COTExitRecorder alloc] init];
    COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:configurationWithCommand(command)];
    [session setDelegate:recorder];
    NSError *error = nil;
    expect([session startWithError:&error], "an interactive shell should start");
    runUntil(1.0, ^BOOL { [session poll]; return NO; });
    [session sendInput:[typed dataUsingEncoding:NSUTF8StringEncoding]];
    BOOL sawRun = runUntil(10.0, ^BOOL {
      [session poll];
      return linesContain(session, ran);
    });
    if (!sawRun) dumpLines(session);
    expect(sawRun, "the shell should run what's typed");

    [session resizeToColumns:100 rows:30];
    runUntil(0.5, ^BOOL { [session poll]; return NO; });
    [session sendInput:[sizeQuery dataUsingEncoding:NSUTF8StringEncoding]];
    BOOL sawSize = runUntil(10.0, ^BOOL {
      [session poll];
      return linesContain(session, sizeShown);
    });
    if (!sawSize) dumpLines(session);
    expect(sawSize, "the shell should see the resized window");
    expect([session columns] == 100 && [session rows] == 30, "the session should report its new size");

    [session terminate];
    expect(![session isRunning], "a terminated session isn't running");
    runUntil(0.5, ^BOOL { return NO; });
    expect([recorder exits] == 0, "terminate shouldn't report an exit");
    [session setDelegate:nil];
    [session release];
    [recorder release];
  }

  // 3. A command that doesn't exist.
  {
#if defined(_WIN32)
    COTTerminalSession *session = [[COTTerminalSession alloc]
      initWithConfiguration:configurationWithCommand([NSArray arrayWithObject:@"cot-no-such-program.exe"])];
    NSError *error = nil;
    expect(![session startWithError:&error], "a missing program shouldn't start");
    expect([[error localizedDescription] length] > 0, "a failed start should say why");
    [session release];
#endif
  }

  [pool drain];
  std::cout << "shell session checks pass\n";
  return 0;
}
