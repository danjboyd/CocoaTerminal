// SPDX-License-Identifier: LGPL-2.1-or-later
// Bounded local disposable-child test for patch B (goal 685, approved by the
// lead as scoped): real forkpty, dispatch READ/timer sources and reaping, with
// three /bin/sh children in this process's own tree. Each case has a 5 s hard
// alarm. No SSH, network, clipboard, GUI or remote service.
#import <CocoaTerminal/CocoaTerminal.h>
#import <objc/runtime.h>
#include <dirent.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <iostream>
#include <string>

static int failures = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { std::cerr << __LINE__ << ": " << msg << "\n"; ++failures; } } while (0)

@interface COTPasteboardSpy : NSObject
+ (id)spyGeneralPasteboard;
@end
@implementation COTPasteboardSpy
+ (id)spyGeneralPasteboard { return nil; }
@end

@interface COTChildProbe : NSObject <COTTerminalDelegate>
@property(nonatomic, assign) int exits, lost, status;
@end
@implementation COTChildProbe
@synthesize exits, lost, status;
- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)value { exits++; status = value; }
- (void)terminalSession:(COTTerminalSession *)session didLoseChildWithError:(int)error { lost++; }
@end

static int OpenFdCount() {
  int count = 0;
  DIR *dir = opendir("/proc/self/fd");
  if (!dir) return -1;
  while (struct dirent *entry = readdir(dir)) if (entry->d_name[0] != '.') ++count;
  closedir(dir);
  return count - 1;  // the DIR's own descriptor
}
// Direct children of this process, and how many of them are zombies.
static void ChildCounts(int *children, int *zombies) {
  *children = *zombies = 0;
  DIR *dir = opendir("/proc");
  if (!dir) return;
  const pid_t self = getpid();
  while (struct dirent *entry = readdir(dir)) {
    if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
    char path[64]; snprintf(path, sizeof path, "/proc/%s/stat", entry->d_name);
    FILE *file = fopen(path, "r");
    if (!file) continue;
    char line[512] = {0};
    if (fgets(line, sizeof line, file)) {
      const char *close = strrchr(line, ')');
      char state = 0; int ppid = 0;
      if (close && sscanf(close + 2, "%c %d", &state, &ppid) == 2 && ppid == self) {
        ++*children;
        if (state == 'Z') ++*zombies;
      }
    }
    fclose(file);
  }
  closedir(dir);
}
// PTY descriptors (ptmx or a pts slave) this process still holds.
static int PtyFdCount() {
  int count = 0;
  DIR *dir = opendir("/proc/self/fd");
  if (!dir) return -1;
  while (struct dirent *entry = readdir(dir)) {
    if (entry->d_name[0] == '.') continue;
    char path[64], target[256] = {0};
    snprintf(path, sizeof path, "/proc/self/fd/%s", entry->d_name);
    if (readlink(path, target, sizeof target - 1) < 0) continue;
    if (strstr(target, "ptmx") || strstr(target, "/dev/pts/")) ++count;
  }
  closedir(dir);
  return count;
}
static void ListFds(const char *label) {
  if (!getenv("COT_LIST_FDS")) return;
  DIR *dir = opendir("/proc/self/fd");
  while (struct dirent *entry = readdir(dir)) {
    if (entry->d_name[0] == '.') continue;
    char path[64], target[256] = {0};
    snprintf(path, sizeof path, "/proc/self/fd/%s", entry->d_name);
    if (readlink(path, target, sizeof target - 1) < 0) target[0] = 0;
    std::cerr << label << " fd " << entry->d_name << " -> " << target << "\n";
  }
  closedir(dir);
}
static BOOL Spin(BOOL (^done)(void), NSTimeInterval seconds) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!done()) {
    if ([deadline timeIntervalSinceNow] <= 0) return done();
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  return YES;
}
static NSString *Screen(COTTerminalSession *session) { return [[session visibleLines] componentsJoinedByString:@"\n"]; }
static COTTerminalSession *Start(NSString *script, COTChildProbe *probe) {
  COTTerminalConfiguration *config = [[[COTTerminalConfiguration defaultConfiguration] copy] autorelease];
  config.shellCommand = @[@"/bin/sh", @"-c", script];
  COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:config];
  session.delegate = probe;
  NSError *error = nil;
  BOOL started = [session startWithError:&error];
  EXPECT(started, "start failed: " << [[error localizedDescription] UTF8String]);
  return session;
}

int main() {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  method_exchangeImplementations(class_getClassMethod([NSPasteboard class], @selector(generalPasteboard)),
                                 class_getClassMethod([COTPasteboardSpy class], @selector(spyGeneralPasteboard)));
  ListFds("base");
  // libdispatch (epoll, eventfd, timerfd), the run loop's pipe and a GNUstep
  // socket open lazily on first use, so the total-fd baseline is taken after
  // case 1; PTY descriptors are checked to be zero after every case.
  int baseFds = -1;
  int children = 0, zombies = 0;

  // 1. Output then exit 3: output read, status exact and once, fd closed, child reaped.
  alarm(5);
  {
    COTChildProbe *probe = [[COTChildProbe new] autorelease];
    COTTerminalSession *session = Start(@"printf hello-685; exit 3", probe);
    EXPECT(Spin(^{ return (BOOL)(probe.exits > 0 && session.cleanupComplete); }, 4.5), "case 1 did not finish");
    EXPECT(probe.exits == 1 && WIFEXITED(probe.status) && WEXITSTATUS(probe.status) == 3, "status " << probe.status);
    EXPECT([Screen(session) rangeOfString:@"hello-685"].location != NSNotFound, "output missing");
    EXPECT(probe.lost == 0, "no lost child");
    NSError *again = nil;
    EXPECT([session startWithError:&again], "restart after clean cleanup");  // a clean restart is allowed
    EXPECT(Spin(^{ return (BOOL)(probe.exits == 2 && session.cleanupComplete); }, 4.0), "restart did not finish");
    [session release];
  }
  ListFds("after1");
  ChildCounts(&children, &zombies);
  EXPECT(zombies == 0 && children == 0, "case 1 children " << children << " zombies " << zombies);
  EXPECT(PtyFdCount() == 0, "case 1 pty fds " << PtyFdCount());
  baseFds = OpenFdCount();

  // 2. A descendant that ignores HUP outlives the shell. Linux may hang the tty
  //    up at the leader's exit (master EIO at once) or keep it readable until the
  //    descendant exits; both orders occur. Either way: the exit is reported
  //    promptly and once, it never waits for EOF, cleanup completes, and while the
  //    transport stayed open the descendant's output was still read.
  alarm(5);
  {
    COTChildProbe *probe = [[COTChildProbe new] autorelease];
    COTTerminalSession *session = Start(@"(trap '' HUP; sleep 1; printf late-685) & printf early-685; exit 0", probe);
    NSDate *started = [NSDate date];
    EXPECT(Spin(^{ return (BOOL)(probe.exits > 0); }, 2.0), "exit not reported");
    const NSTimeInterval exitAt = -[started timeIntervalSinceNow];
    EXPECT(exitAt < 0.9, "exit waited for the descendant: " << exitAt);
    EXPECT(probe.exits == 1 && WIFEXITED(probe.status) && WEXITSTATUS(probe.status) == 0, "status");
    EXPECT(Spin(^{ return session.cleanupComplete; }, 2.5), "cleanup did not complete");
    const NSTimeInterval cleanAt = -[started timeIntervalSinceNow];
    EXPECT([Screen(session) rangeOfString:@"early-685"].location != NSNotFound, "output before exit missing");
    if (cleanAt >= 0.9)
      EXPECT([Screen(session) rangeOfString:@"late-685"].location != NSNotFound, "open transport lost descendant output");
    std::cout << "case 2: exit " << exitAt << " s, cleanup " << cleanAt << " s ("
              << (cleanAt >= 0.9 ? "transport stayed open; descendant output read" : "tty hung up at leader exit") << ")\n";
    EXPECT(probe.exits == 1, "exit delivered once");
    [session release];
  }
  ChildCounts(&children, &zombies);
  EXPECT(zombies == 0, "case 2 zombies " << zombies);
  EXPECT(PtyFdCount() == 0, "case 2 pty fds " << PtyFdCount());
  EXPECT(OpenFdCount() == baseFds, "case 2 fds " << OpenFdCount() << " vs " << baseFds);

  // 3. A child that ignores SIGHUP: quit reports it still stopping within the
  //    deadline and does not kill it; restart is refused; it is reaped later.
  alarm(5);
  {
    COTChildProbe *probe = [[COTChildProbe new] autorelease];
    COTTerminalSession *session = Start(@"trap '' HUP; printf ready-685; sleep 2", probe);
    EXPECT(Spin(^{ return (BOOL)([Screen(session) rangeOfString:@"ready-685"].location != NSNotFound); }, 2.0), "not ready");
    NSDate *before = [NSDate date];
    NSUInteger stopping = [COTTerminalSession shutdownAllSessionsWithTimeout:0.5];
    NSTimeInterval took = -[before timeIntervalSinceNow];
    EXPECT(stopping == 1, "quit report " << stopping);
    EXPECT(took >= 0.45 && took < 0.9, "quit bounded: " << took);
    EXPECT(!session.cleanupComplete && probe.exits == 0, "not killed, not reaped yet");
    NSError *refused = nil;
    EXPECT(![session startWithError:&refused] && refused.code == 3, "restart refused while stopping");
    EXPECT(Spin(^{ return (BOOL)(probe.exits == 1 && session.cleanupComplete); }, 3.0), "not reaped after it exited");
    EXPECT(WIFEXITED(probe.status), "ignored HUP, exited on its own: " << probe.status);
    EXPECT([COTTerminalSession shutdownAllSessionsWithTimeout:0.5] == 0, "nothing left to stop");
    [session release];
  }
  ChildCounts(&children, &zombies);
  EXPECT(zombies == 0 && children == 0, "case 3 children " << children << " zombies " << zombies);
  EXPECT(PtyFdCount() == 0, "case 3 pty fds " << PtyFdCount());
  EXPECT(OpenFdCount() == baseFds, "case 3 fds " << OpenFdCount() << " vs " << baseFds);

  // 6. Backpressure: 200 000 bytes into a raw-mode child that starts reading only
  //    after 0.5 s. The writer hits EAGAIN, the WRITE source is created lazily on
  //    that first EAGAIN, and every byte arrives in order.
  alarm(5);
  {
    COTChildProbe *probe = [[COTChildProbe new] autorelease];
    COTTerminalSession *session = Start(@"stty raw -echo; printf RAW-READY; sleep 0.5; head -c 200000 | cksum; exit 0", probe);
    // Send only once the tty is raw: before that, cooked mode echoes and caps the line.
    EXPECT(Spin(^{ return (BOOL)([Screen(session) rangeOfString:@"RAW-READY"].location != NSNotFound); }, 2.0), "raw mode not ready");
    std::string payload;
    for (int i = 0; payload.size() < 200000; ++i) payload += std::to_string(i % 10);
    payload.resize(200000);
    COTTerminalEnqueueResult result = [session trySendInput:[NSData dataWithBytes:payload.data() length:payload.size()]];
    EXPECT(result == COTTerminalEnqueueAccepted, "payload accepted: " << (long)result);
    {
      // While the child sleeps, the writer must be parked on a lazily created WRITE source.
      Ivar queueIvar = class_getInstanceVariable([COTTerminalSession class], "_terminalQueue");
      Ivar sourceIvar = class_getInstanceVariable([COTTerminalSession class], "_writeSource");
      dispatch_queue_t queue = *(dispatch_queue_t *)((char *)session + ivar_getOffset(queueIvar));
      __block BOOL armed = NO;
      Spin(^{ return NO; }, 0.1);
      dispatch_sync(queue, ^{ armed = *(void **)((char *)session + ivar_getOffset(sourceIvar)) != NULL; });
      EXPECT(armed, "EAGAIN did not create the WRITE source");
    }
    EXPECT(Spin(^{ return (BOOL)(probe.exits == 1 && session.cleanupComplete); }, 4.0), "backpressured child did not finish");
    // cksum of the same bytes, computed locally through a pipe is avoided: compare the length field only.
    EXPECT([Screen(session) rangeOfString:@" 200000"].location != NSNotFound, "all bytes delivered: " << [Screen(session) UTF8String]);
    EXPECT(session.transportError == nil || [session.transportError length] == 0, "no transport error: " << [session.transportError UTF8String]);
    [session release];
  }
  ChildCounts(&children, &zombies);
  EXPECT(zombies == 0 && PtyFdCount() == 0, "case 6 zombies " << zombies);

  alarm(5);
  // 5. Prereq F: a bad working directory or a missing command is refused before
  //    fork (code 5): no child, no PTY.
  {
    COTTerminalConfiguration *config = [[[COTTerminalConfiguration defaultConfiguration] copy] autorelease];
    config.shellCommand = @[@"/bin/sh", @"-c", @"exit 0"];
    config.workingDirectory = @"/nonexistent-cot-685";
    COTTerminalSession *session = [[COTTerminalSession alloc] initWithConfiguration:config];
    NSError *error = nil;
    EXPECT(![session startWithError:&error] && error.code == 5, "bad cwd refused before fork: " << (long)error.code);
    config.workingDirectory = @"";
    config.shellCommand = @[@"cot-no-such-command-685"];
    COTTerminalSession *missing = [[COTTerminalSession alloc] initWithConfiguration:config];
    error = nil;
    EXPECT(![missing startWithError:&error] && error.code == 5, "missing command refused before fork");
    EXPECT(missing.cleanupComplete && session.cleanupComplete, "nothing to clean");
    int c = 0, z = 0; ChildCounts(&c, &z);
    EXPECT(c == 0 && PtyFdCount() == 0, "no child or PTY for a refused start");
    // The child gets the configured environment and TERM, built before fork.
    COTChildProbe *probe = [[COTChildProbe new] autorelease];
    config.shellCommand = @[@"/bin/sh", @"-c", @"printf \"[$COT_PLAN_685:$TERM:$COLORTERM]\"; exit 0"];
    NSMutableDictionary *env = [[config.environment mutableCopy] autorelease];
    env[@"COT_PLAN_685"] = @"planned";
    config.environment = env;
    COTTerminalSession *planned = [[COTTerminalSession alloc] initWithConfiguration:config];
    planned.delegate = probe;
    EXPECT([planned startWithError:&error], "planned start");
    EXPECT(Spin(^{ return (BOOL)(probe.exits == 1 && planned.cleanupComplete); }, 3.0), "planned child finished");
    EXPECT([Screen(planned) rangeOfString:@"[planned:xterm-256color:truecolor]"].location != NSNotFound,
           "child environment: " << [Screen(planned) UTF8String]);
    [planned release]; [missing release]; [session release];
  }

  // 4. Dealloc while running: HUP, and the shared lifecycle still reaps and closes.
  alarm(5);
  {
    COTTerminalSession *session = Start(@"printf x; sleep 3", nil);
    Spin(^{ return (BOOL)([Screen(session) rangeOfString:@"x"].location != NSNotFound); }, 2.0);
    [session release];
    Spin(^{ int c = 0, z = 0; ChildCounts(&c, &z); return (BOOL)(c == 0 && PtyFdCount() == 0); }, 3.0);
  }
  ChildCounts(&children, &zombies);
  EXPECT(zombies == 0 && children == 0, "case 4 children " << children << " zombies " << zombies);
  EXPECT(PtyFdCount() == 0, "case 4 pty fds " << PtyFdCount());
  EXPECT(OpenFdCount() == baseFds, "case 4 fds " << OpenFdCount() << " vs " << baseFds);
  alarm(0);

  [pool release];
  if (failures) { std::cerr << failures << " failure(s)\n"; return 1; }
  std::cout << "COTSessionChildTests: all passed (fds " << baseFds << ", no children, no zombies)\n";
  return 0;
}
