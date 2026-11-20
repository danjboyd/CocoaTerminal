// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// How fast the terminal view draws, and how fast output gets through. Not a test: it prints numbers.
//
//   CocoaTerminalBench [--columns N] [--rows N] [--frames N] [--megabytes N] [--font FAMILY] [--size PT] [--only NAME]
//
// render-ascii, render-colour, render-unicode: a full screen of that content, then N forced full redraws of the view
//   ([view display]: drawRect plus the flush to the window); the time per frame is what a GPU renderer would change.
// throughput-session: N MB of coloured log lines through the shell into a session with no view (parsing only).
// throughput-view: the same into a view in a window, at the view's normal frame cap; reports frames drawn.
//
// The shell is MSYS2's sh on Windows (COCOATERMINAL_BENCH_SHELL overrides) and /bin/sh elsewhere.

#import <CocoaTerminal/CocoaTerminal.h>
#import <AppKit/AppKit.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

static NSString *BenchShell(void) {
  const char *configured = getenv("COCOATERMINAL_BENCH_SHELL");
  if (configured != NULL && *configured) return [NSString stringWithUTF8String:configured];
#if defined(_WIN32)
  return @"C:\\msys64\\usr\\bin\\sh.exe";
#else
  return @"/bin/sh";
#endif
}

// A path the shell's cat can open: forward slashes work for MSYS2 and for everything else.
static NSString *ShellPath(NSString *path) {
  return [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

static void Spin(NSTimeInterval seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) {
    // Each pass drains its own objects, as the app's event loop would; without this a run held tens of GB.
    @autoreleasepool {
      NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]
                                             inMode:NSDefaultRunLoopMode dequeue:YES];
      if (event != nil) [NSApp sendEvent:event];
    }
  }
}

static BOOL SpinUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([until timeIntervalSinceNow] > 0) {
    @autoreleasepool {
      if (done()) return YES;
    }
    Spin(0.01);
  }
  @autoreleasepool {
    return done();
  }
}

#if defined(_WIN32)
extern "C" double COTBenchPrivateMegabytes(void);  // bench/COTBenchMemory.cpp
#endif

// The process's private bytes (resident on Linux), in MB: enough to see whether something grows frame by frame.
static double PrivateMegabytes(void) {
#if defined(_WIN32)
  return COTBenchPrivateMegabytes();
#else
  FILE *f = fopen("/proc/self/statm", "r");
  long pages = 0, resident = 0;
  if (f) {
    if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = 0;
    fclose(f);
  }
  return resident * 4096.0 / 1048576.0;
#endif
}

static BOOL AnyLineContains(COTTerminalSession *session, NSString *needle) {
  for (NSString *line in [session visibleLines]) {
    if ([line rangeOfString:needle].location != NSNotFound) return YES;
  }
  return NO;
}

static NSString *WriteTemp(NSString *name, const std::string &bytes) {
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
  if (![data writeToFile:path atomically:YES]) {
    fprintf(stderr, "could not write %s\n", [path UTF8String]);
    exit(2);
  }
  return path;
}

// One full screen, cursor hidden; the last row ends with the sentinel.
static std::string Screen(const std::string &kind, unsigned columns, unsigned rows, const std::string &sentinel) {
  std::string out = "\033[?25l\033[H\033[2J";
  static const char *words = "the quick brown fox jumps over the lazy dog 0123456789 {}[]()<>=+-*/ ";
  static const char *unicode[] = {"─", "│", "┌", "┐", "└", "┘", "├", "┤", "α", "β", "γ", "λ", "é", "ü", "ñ", "→", "•", "█"};
  std::size_t w = 0;
  for (unsigned r = 0; r < rows; r++) {
    unsigned last = (r == rows - 1) ? columns - (unsigned)sentinel.size() - 1 : columns;
    for (unsigned c = 0; c < last; c++) {
      char ch = words[w++ % 70];
      if (kind == "colour") {
        char sgr[48];
        snprintf(sgr, sizeof sgr, "\033[38;5;%u;48;5;%um", 16 + (r * 7 + c) % 216, 232 + (r + c) % 24);
        out += sgr;
        out += ch;
      } else if (kind == "unicode") {
        out += ((r + c) % 3 == 0) ? std::string(unicode[(r * 5 + c) % 18]) : std::string(1, ch);
      } else {
        out += ch;
      }
    }
    if (kind == "colour") out += "\033[0m";
    if (r == rows - 1) {
      out += " " + sentinel;
    } else {
      out += "\r\n";
    }
  }
  return out;
}

// Coloured log lines, about megabytes MB, then the sentinel on its own line.
static std::string Log(double megabytes, const std::string &sentinel) {
  std::string out;
  std::size_t target = (std::size_t)(megabytes * 1024 * 1024);
  out.reserve(target + 256);
  static const char *levels[] = {"\033[32mINFO \033[0m", "\033[33mWARN \033[0m", "\033[31mERROR\033[0m", "\033[36mDEBUG\033[0m"};
  for (unsigned long n = 0; out.size() < target; n++) {
    char line[256];
    snprintf(line, sizeof line, "\033[90m2026-11-19T12:%02lu:%02lu.%03lu\033[0m %s \033[1mworker-%lu\033[0m handled request %lu in %lu ms\r\n",
             (n / 60) % 60, n % 60, n % 1000, levels[n % 4], n % 16, n, (n * 37) % 900);
    out += line;
  }
  out += sentinel + "\r\n";
  return out;
}

@interface Bench : NSObject
@property (nonatomic) unsigned columns, rows, frames;
@property (nonatomic) double megabytes, fontSize;
@property (nonatomic) BOOL cmdProducer;  // throughput: cmd.exe's `type` writes the file, not MSYS2's cat
@property (nonatomic, copy) NSString *fontFamily;
@end

@implementation Bench

- (COTTerminalConfiguration *)configuration {
  COTTerminalConfiguration *configuration = [[[COTTerminalConfiguration defaultConfiguration] copy] autorelease];
  // The shell reads a path, cats it, and waits for the next one; nothing it types itself shows.
  NSString *script = @"stty -echo 2>/dev/null; while IFS= read -r f; do cat \"$f\"; done";
  [configuration setShellCommand:[NSArray arrayWithObjects:BenchShell(), @"-c", script, nil]];
  COTTerminalTheme *theme = [configuration theme];
  if (_fontFamily) [theme setFontFamily:_fontFamily];
  if (_fontSize > 0) [theme setFontSize:_fontSize];
  return configuration;
}

// The view's frame for columns x rows, from the theme's font as the view measures it.
- (NSRect)frameForConfiguration:(COTTerminalConfiguration *)configuration {
  COTTerminalTheme *theme = [configuration theme];
  NSFont *font = [theme font];
  CGFloat cellWidth = [@"M" sizeWithAttributes:[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;
  CGFloat lineHeight = [font ascender] - [font descender] + [theme lineSpacing];
  NSEdgeInsets insets = [theme contentInsets];
  return NSMakeRect(0, 0, ceil(cellWidth * _columns + insets.left + insets.right) + 1,
                    ceil(lineHeight * _rows + insets.top + insets.bottom) + 1);
}

- (void)sendPath:(NSString *)path to:(COTTerminalSession *)session {
  NSString *line = [ShellPath(path) stringByAppendingString:@"\r"];
  [session sendInput:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)render:(NSString *)kind {
  COTTerminalConfiguration *configuration = [self configuration];
  NSRect frame = [self frameForConfiguration:configuration];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                   backing:NSBackingStoreBuffered defer:NO];
  COTTerminalView *view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
  [window setTitle:@"CocoaTerminal bench"];
  [window setContentView:view];
  [window orderFrontRegardless];
  [window makeFirstResponder:nil];  // no cursor drawn
  NSError *error = nil;
  if (![view startTerminalWithError:&error]) {
    fprintf(stderr, "render-%s: the shell didn't start: %s\n", [kind UTF8String], [[error description] UTF8String]);
    exit(2);
  }
  COTTerminalSession *session = [view session];
  Spin(1.0);  // the view sizes the terminal after a short delay
  unsigned columns = (unsigned)[session columns], rows = (unsigned)[session rows];
  std::string sentinel = "END-" + std::string([kind UTF8String]);
  NSString *path = WriteTemp([NSString stringWithFormat:@"cot-bench-%@.txt", kind], Screen([kind UTF8String], columns, rows, sentinel));
  [self sendPath:path to:session];
  NSString *needle = [NSString stringWithUTF8String:sentinel.c_str()];
  if (!SpinUntil(30, ^BOOL { return AnyLineContains(session, needle); })) {
    fprintf(stderr, "render-%s: the screen never arrived\n", [kind UTF8String]);
    exit(2);
  }
  Spin(0.5);

  for (unsigned i = 0; i < 5; i++) {  // warm the font and glyph caches
    @autoreleasepool {
      [view display];
    }
  }
  std::vector<double> times;
  double memoryBefore = PrivateMegabytes();
  for (unsigned i = 0; i < _frames; i++) {
    @autoreleasepool {
      NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
      [view display];
      times.push_back(([NSDate timeIntervalSinceReferenceDate] - start) * 1000.0);
    }
  }
  double memoryAfter = PrivateMegabytes();
  std::sort(times.begin(), times.end());
  double total = 0;
  for (double t : times) total += t;
  printf("render-%-8s %ux%u  frames=%u  mean=%.2f ms  median=%.2f ms  p95=%.2f ms  (%.0f fps)\n", [kind UTF8String],
         columns, rows, _frames, total / times.size(), times[times.size() / 2], times[(times.size() * 95) / 100],
         1000.0 / (total / times.size()));
  printf("                   memory %.0f MB -> %.0f MB over %u frames (%.1f KB/frame)\n", memoryBefore, memoryAfter, _frames,
         (memoryAfter - memoryBefore) * 1024.0 / _frames);
  fflush(stdout);

  [session terminate];
  [window close];
  [view release];
}

- (void)throughputWithView:(BOOL)withView {
  const char *name = withView ? "throughput-view" : "throughput-session";
  COTTerminalConfiguration *configuration = [self configuration];
  std::string sentinel = std::string("BENCH-DONE-") + name;
  NSString *path = WriteTemp([NSString stringWithFormat:@"cot-bench-%s.txt", name], Log(_megabytes, sentinel));
  unsigned long long bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileSize];
  NSTimeInterval start = 0;
  if (_cmdProducer) {
    // MSYS2's programs write to a console through Cygwin's layer, about ten times slower than a native one.
    NSString *windowsPath = [path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    NSString *line = [NSString stringWithFormat:@"type %@ & ping -n 900 127.0.0.1 >nul", windowsPath];
    [configuration setShellCommand:[NSArray arrayWithObjects:@"cmd.exe", @"/d", @"/c", line, nil]];
    fprintf(stderr, "producer: cmd.exe /d /c %s\n", [line UTF8String]);
  }
  NSWindow *window = nil;
  COTTerminalView *view = nil;
  COTTerminalSession *session = nil;
  NSError *error = nil;
  if (_cmdProducer) start = [NSDate timeIntervalSinceReferenceDate];  // cmd starts typing as soon as it runs
  if (withView) {
    NSRect frame = [self frameForConfiguration:configuration];
    window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    view = [[COTTerminalView alloc] initWithFrame:frame configuration:configuration];
    [window setTitle:@"CocoaTerminal bench"];
    [window setContentView:view];
    [window orderFrontRegardless];
    if (![view startTerminalWithError:&error]) {
      fprintf(stderr, "%s: the shell didn't start\n", name);
      exit(2);
    }
    session = [view session];
  } else {
    session = [[COTTerminalSession alloc] initWithConfiguration:configuration];
    [session resizeToColumns:_columns rows:_rows];
    if (![session startWithError:&error]) {
      fprintf(stderr, "%s: the shell didn't start\n", name);
      exit(2);
    }
  }
  if (!_cmdProducer) Spin(1.0);
  NSDictionary *before = [view performanceSnapshot];
  NSString *needle = [NSString stringWithUTF8String:sentinel.c_str()];
  if (!_cmdProducer) {
    start = [NSDate timeIntervalSinceReferenceDate];
    [self sendPath:path to:session];
  }
  BOOL arrived = SpinUntil(600, ^BOOL { return AnyLineContains(session, needle); });
  NSTimeInterval seconds = [NSDate timeIntervalSinceReferenceDate] - start;
  if (!arrived) {
    fprintf(stderr, "%s: the output never finished\n", name);
    exit(2);
  }
  printf("%-18s %.1f MB in %.2f s  = %.1f MB/s", name, bytes / 1048576.0, seconds, bytes / 1048576.0 / seconds);
  if (withView) {
    NSDictionary *after = [view performanceSnapshot];
    unsigned long draws = [[after objectForKey:@"drawCalls"] unsignedLongValue] - [[before objectForKey:@"drawCalls"] unsignedLongValue];
    printf("  draws=%lu (%.1f/s, cap %.0f)", draws, draws / seconds, [[after objectForKey:@"maxFPS"] doubleValue]);
  }
  printf("\n");
  fflush(stdout);
  [session terminate];
  if (withView) {
    [window close];
    [view release];
  } else {
    [session release];
  }
}

@end

// Set once the app has finished launching. GNUstep can hang before that (with no services cache it runs make_services,
// which needs gdnc), and the bench would wait silently: a watchdog says so and exits after 60 s.
static std::atomic<bool> gLaunched(false);

// Runs once the app has finished launching, as the demo's delegate does: GNUstep on Windows throws if a window is
// shown before then.
@interface BenchDelegate : NSObject
@property (nonatomic, retain) Bench *bench;
@property (nonatomic, copy) NSString *only;
@property (nonatomic) int status;
@end

@implementation BenchDelegate
// Each section closes its window; on Linux GNUstep then quit the bench after the first one (exit 0, nothing more run).
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  (void)app;
  return NO;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  gLaunched.store(true);
  (void)notification;
  COTTerminalTheme *theme = [[_bench configuration] theme];
  printf("font %s %.0f pt (%s)\n", [[theme fontFamily] UTF8String], [theme fontSize], [[[theme font] fontName] UTF8String]);
  fflush(stdout);
  @try {
    for (NSString *kind in @[@"ascii", @"colour", @"unicode"]) {
      if (_only == nil || [_only isEqualToString:[@"render-" stringByAppendingString:kind]]) [_bench render:kind];
    }
    if (_only == nil || [_only isEqualToString:@"throughput-session"]) [_bench throughputWithView:NO];
    if (_only == nil || [_only isEqualToString:@"throughput-view"]) [_bench throughputWithView:YES];
  } @catch (NSException *e) {
    fprintf(stderr, "%s: %s\n", [[e name] UTF8String], [[e reason] UTF8String]);
    _status = 3;
  }
  fflush(stdout);
  exit(_status);
}
@end

int main(int argc, char **argv) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  // As the demo does: no menu window.
  [[NSUserDefaults standardUserDefaults] setObject:@"NSWindows95InterfaceStyle" forKey:@"NSMenuInterfaceStyle"];
  Bench *bench = [[[Bench alloc] init] autorelease];
  bench.columns = 160;
  bench.rows = 48;
  bench.frames = 200;
  bench.megabytes = 20;
  NSString *only = nil;
  for (int i = 1; i + 1 < argc; i += 2) {
    std::string flag = argv[i];
    const char *value = argv[i + 1];
    if (flag == "--columns") bench.columns = (unsigned)atoi(value);
    else if (flag == "--rows") bench.rows = (unsigned)atoi(value);
    else if (flag == "--frames") bench.frames = (unsigned)atoi(value);
    else if (flag == "--megabytes") bench.megabytes = atof(value);
    else if (flag == "--font") bench.fontFamily = [NSString stringWithUTF8String:value];
    else if (flag == "--size") bench.fontSize = atof(value);
    else if (flag == "--only") only = [NSString stringWithUTF8String:value];
    else if (flag == "--producer") bench.cmdProducer = std::string(value) == "cmd";
    else {
      fprintf(stderr, "unknown option %s\n", argv[i]);
      return 2;
    }
  }
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(60));
    if (!gLaunched.load()) {
      fprintf(stderr, "CocoaTerminalBench: the application hadn't finished launching after 60 s (is GNUstep's gdnc "
                      "running, and its services cache made?): giving up\n");
      fflush(stderr);
      std::_Exit(2);
    }
  }).detach();
  NSApplication *app = [NSApplication sharedApplication];
  BenchDelegate *delegate = [[BenchDelegate alloc] init];
  delegate.bench = bench;
  delegate.only = only;
  [app setDelegate:delegate];
  [app run];
  [pool drain];
  return 0;
}
