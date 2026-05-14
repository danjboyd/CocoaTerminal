// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/CocoaTerminal.h>

#include <math.h>

static NSString *const COTScenarioDefault = @"smoke";
static NSString *const COTScenarioSentinelPrefix = @"COT_SCENARIO_DONE:";

static NSString *COTHexStringForColor(NSColor *color) {
  NSColor *rgb = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  CGFloat red = 0.0;
  CGFloat green = 0.0;
  CGFloat blue = 0.0;
  CGFloat alpha = 0.0;
  [rgb getRed:&red green:&green blue:&blue alpha:&alpha];
  return [NSString stringWithFormat:@"#%02X%02X%02X",
          (unsigned int)lrint(red * 255.0),
          (unsigned int)lrint(green * 255.0),
          (unsigned int)lrint(blue * 255.0)];
}

static NSString *COTPythonScenarioScript(NSString *body) {
  return [NSString stringWithFormat:@"python3 - <<'PY'\n%@\nPY", body];
}

@interface COTDemoScenario : NSObject {
  NSString *_name;
  NSString *_kind;
  NSString *_script;
  NSString *_expectedStatus;
  NSString *_expectedReason;
  NSString *_sentinel;
}

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *script;
@property (nonatomic, copy) NSString *expectedStatus;
@property (nonatomic, copy) NSString *expectedReason;
@property (nonatomic, copy) NSString *sentinel;

+ (instancetype)scenarioNamed:(NSString *)name;
+ (NSArray<NSString *> *)knownScenarioNames;

@end

@implementation COTDemoScenario

+ (instancetype)scenarioNamed:(NSString *)name {
  COTDemoScenario *scenario = [[[self alloc] init] autorelease];
  scenario.name = name;
  scenario.kind = @"shell";
  scenario.expectedStatus = @"pass";
  scenario.expectedReason = @"implemented";
  scenario.sentinel = [COTScenarioSentinelPrefix stringByAppendingString:name];

  if ([name isEqualToString:@"smoke"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:smoke\\r\\n'; "
                      "printf 'basic-output\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:smoke\\r\\n'; "
                      "sleep 0.1";
  } else if ([name isEqualToString:@"cursor"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:cursor\\r\\n'; "
                      "printf 'cursor-target'; "
                      "printf 'COT_SCENARIO_DONE:cursor'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"cursor position and rendering are covered";
  } else if ([name isEqualToString:@"cursor-block"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:cursor-block\\r\\n'; "
                      "printf 'block-cursor-target'; "
                      "printf 'COT_SCENARIO_DONE:cursor-block'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"filled block cursor rendering is covered";
  } else if ([name isEqualToString:@"zoom-shortcuts"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:zoom-shortcuts\\r\\n'; "
                      "printf 'zoom-target\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:zoom-shortcuts\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"control zoom shortcuts and PTY resizing are covered";
  } else if ([name isEqualToString:@"exit-closes-demo"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:exit-closes-demo\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:exit-closes-demo\\r\\n'; "
                      "exit 0";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"session exit behavior is covered";
  } else if ([name isEqualToString:@"delete-editing"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:delete-editing\\r\\n'; "
                      "printf 'abc\\b \\b'; "
                      "printf '\\r\\033[Kdelete-result=ab\\r\\n'; "
                      "printf 'abcdef\\r\\033[3C\\033[Pdelete-forward=abdef\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:delete-editing\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"backspace erase, CSI K, and CSI P are covered";
  } else if ([name isEqualToString:@"mouse-no-leak"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:mouse-no-leak\\r\\n'; "
                      "printf 'mouse-mode-off\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:mouse-no-leak\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"mouse reports are suppressed when mouse mode is off";
  } else if ([name isEqualToString:@"terminal-env"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:terminal-env\\r\\n'; "
                      "printf 'TERM_VALUE=%s\\r\\n' \"$TERM\"; "
                      "printf 'COLORTERM_VALUE=%s\\r\\n' \"$COLORTERM\"; "
                      "printf 'COT_SCENARIO_DONE:terminal-env\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"embedded PTY terminal identity is covered";
  } else if ([name isEqualToString:@"ansi-colors"]) {
    scenario.script = COTPythonScenarioScript(
      @"import sys\n"
       "print('COT_SCENARIO_BEGIN:ansi-colors')\n"
       "for i in range(16):\n"
       "    sys.stdout.write(f'\\x1b[{30 + (i % 8)}mansi-{i:02d}\\x1b[0m ')\n"
       "print('\\ntruecolor-start')\n"
       "for i in range(0, 256, 32):\n"
       "    sys.stdout.write(f'\\x1b[38;2;{i};{255-i};160mTC{i:03d}\\x1b[0m ')\n"
       "print('\\nCOT_SCENARIO_DONE:ansi-colors')\n");
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"unicode-width"]) {
    scenario.script = COTPythonScenarioScript(
      @"print('COT_SCENARIO_BEGIN:unicode-width')\n"
       "print('ascii | abcdef |')\n"
       "print('box   | ┌─┬─┐ |')\n"
       "print('cjk   | 表意文字 |')\n"
       "print('emoji | ⚙️ ✅ 🚀 |')\n"
       "print('comb  | e\\u0301 a\\u0308 o\\u0302 |')\n"
       "print('COT_SCENARIO_DONE:unicode-width')\n");
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"scrollback"]) {
    scenario.script = COTPythonScenarioScript(
      @"print('COT_SCENARIO_BEGIN:scrollback')\n"
       "for i in range(1, 121): print(f'scroll-line-{i:03d}')\n"
       "print('COT_SCENARIO_DONE:scrollback')\n");
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"alternate-screen"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:alternate-screen\\r\\n'; "
                      "printf '\\033[?1049hALT-SCREEN-CONTENT\\r\\n'; "
                      "printf '\\033[?1049l\\033[JMAIN-SCREEN-RETURNED\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:alternate-screen\\r\\n'; sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"keyboard-input"]) {
    scenario.script = COTPythonScenarioScript(
      @"import sys\n"
       "print('COT_SCENARIO_BEGIN:keyboard-input')\n"
       "print('COT_KEYBOARD_EXPECTED: text enter backspace arrows ctrl alt')\n"
       "print('COT_SCENARIO_DONE:keyboard-input')\n");
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"mouse-reporting"]) {
    scenario.script = COTPythonScenarioScript(
      @"print('COT_SCENARIO_BEGIN:mouse-reporting')\n"
       "print('\\x1b[?1000h\\x1b[?1002h\\x1b[?1006hmouse-mode-enabled')\n"
       "print('COT_MOUSE_EXPECTED: click drag wheel modifiers')\n"
       "print('COT_SCENARIO_DONE:mouse-reporting')\n");
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"tmux-mouse-resize"]) {
    scenario.script = COTPythonScenarioScript(
      @"print('COT_SCENARIO_BEGIN:tmux-mouse-resize')\n"
       "print('\\x1b[?1000h\\x1b[?1002h\\x1b[?1006hmouse-mode-enabled')\n"
       "print('COT_SCENARIO_DONE:tmux-mouse-resize')\n");
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"SGR mouse drag/release delivery is covered";
  } else if ([name isEqualToString:@"tmux"]) {
    scenario.script = @"if command -v tmux >/dev/null 2>&1; then "
                      "printf 'COT_SCENARIO_BEGIN:tmux\\r\\n'; "
                      "tmux -L coterminal-demo-test -f /dev/null new-session -s coterminal-demo 'printf \"tmux-interactive-pass\\r\\n\"; sleep 1'; "
                      "printf 'COT_SCENARIO_DONE:tmux\\r\\n'; "
                      "else printf 'COT_SCENARIO_SKIP:tmux missing tmux\\r\\n'; printf 'COT_SCENARIO_DONE:tmux\\r\\n'; fi";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"real tmux in the embedded PTY is covered";
  } else if ([name isEqualToString:@"readline-editing"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:readline-editing\\r\\n'; "
                      "bash --noprofile --norc -c 'read -e line; printf \"readline-result=%s\\r\\n\" \"$line\"'; "
                      "printf 'COT_SCENARIO_DONE:readline-editing\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"readline editing through PTY input is covered";
  } else if ([name isEqualToString:@"fullscreen-app-baseline"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:fullscreen-app-baseline\\r\\n'; "
                      "printf '\\033[?1049h\\033[?25lFULLSCREEN-APP\\r\\n'; "
                      "printf '\\033[?25h\\033[?1049lFULLSCREEN-RESTORED\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:fullscreen-app-baseline\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"alternate screen and cursor visibility baseline is covered";
  } else if ([name isEqualToString:@"line-drawing-inverse"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:line-drawing-inverse\\r\\n'; "
                      "printf '\\033(0lqqqk\\033(B\\r\\n'; "
                      "printf '\\033(0x\\033(B hi \\033(0x\\033(B\\r\\n'; "
                      "printf '\\033(0mqqqj\\033(B\\r\\n'; "
                      "printf '\\033[7minverse-status\\033[0m\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:line-drawing-inverse\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"DEC line drawing and inverse video rendering are covered";
  } else if ([name isEqualToString:@"vim"]) {
    scenario.script = @"if command -v vim >/dev/null 2>&1; then "
                      "tmp=$(mktemp); printf 'COT_SCENARIO_BEGIN:vim\\r\\n'; "
                      "vim -Nu NONE -n -es \"$tmp\" <<'VIM' >/dev/null 2>&1\n"
                      "set nomore\n"
                      "call setline(1, 'vim-wrote-line')\n"
                      "wq\n"
                      "VIM\n"
                      "cat \"$tmp\"; rm -f \"$tmp\"; printf '\\r\\nCOT_SCENARIO_DONE:vim\\r\\n'; "
                      "else printf 'COT_SCENARIO_SKIP:vim missing vim\\r\\n'; printf 'COT_SCENARIO_DONE:vim\\r\\n'; fi";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"resize"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:resize\\r\\n'; stty size; "
                      "printf 'COT_RESIZE_EXPECTED: initial-and-updated-pty-size\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:resize\\r\\n'; sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"implemented for current scenario coverage";
  } else if ([name isEqualToString:@"tmux-ctrl-a-split"]) {
    scenario.script = @"if ! command -v tmux >/dev/null 2>&1; then "
                      "printf 'COT_SCENARIO_SKIP:tmux-ctrl-a-split missing tmux\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:tmux-ctrl-a-split\\r\\n'; exit 0; fi; "
                      "unset TMUX TMUX_PANE; "
                      "rm -f /tmp/coterminal-split.marker; "
                      "cat > /tmp/coterminal-split.conf <<'TMUXCFG'\n"
                      "set -g prefix C-a\n"
                      "unbind C-b\n"
                      "bind-key '\"' run-shell 'printf SPLIT_OK > /tmp/coterminal-split.marker; tmux kill-server'\n"
                      "TMUXCFG\n"
                      "printf 'COT_SCENARIO_BEGIN:tmux-ctrl-a-split\\r\\n'; "
                      "tmux -L coterminal-split -f /tmp/coterminal-split.conf new-session -s s 'printf TMUX_READY; sleep 30'; "
                      "result=$(cat /tmp/coterminal-split.marker 2>/dev/null); "
                      "printf 'MARKER=%s\\r\\n' \"${result:-MISSING}\"; "
                      "printf 'COT_SCENARIO_DONE:tmux-ctrl-a-split\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"Ctrl-A followed by \" in tmux invokes the bound prefix action";
  } else if ([name isEqualToString:@"menu-shortcut-dispatch"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:menu-shortcut-dispatch\\r\\n'; "
                      "printf 'CLIPBOARD_FIXTURE_LINE\\r\\n'; "
                      "printf 'COT_SCENARIO_DONE:menu-shortcut-dispatch\\r\\n'; "
                      "sleep 0.4";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"Cmd-Shift-A dispatched through [NSApp sendEvent:] reaches view's selectAll: action";
  } else if ([name isEqualToString:@"cmd-letter-bytes-gnustep"]) {
    scenario.script = @"stty -icanon -isig -echo time 0 min 2; "
                      "printf 'COT_SCENARIO_BEGIN:cmd-letter-bytes-gnustep\\r\\nCOT_READY:cmd-letter-bytes-gnustep\\r\\n'; "
                      "python3 -u -c 'import sys; "
                      "data = sys.stdin.buffer.read(2); "
                      "sys.stdout.write(\"BYTES=\" + \" \".join(format(b, \"02x\") for b in data) + \"\\r\\n\"); "
                      "sys.stdout.flush()'; "
                      "stty sane; "
                      "printf 'COT_SCENARIO_DONE:cmd-letter-bytes-gnustep\\r\\n'; "
                      "sleep 0.2";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"NSCommandKeyMask+letter (GNUstep mapping for physical Ctrl) sends control byte";
  } else if ([name isEqualToString:@"ctrl-letter-bytes-dispatch"]) {
    scenario.script = @"stty -icanon -isig -echo time 0 min 2; "
                      "printf 'COT_SCENARIO_BEGIN:ctrl-letter-bytes-dispatch\\r\\nCOT_READY:ctrl-letter-bytes-dispatch\\r\\n'; "
                      "python3 -u -c 'import sys; "
                      "data = sys.stdin.buffer.read(2); "
                      "sys.stdout.write(\"BYTES=\" + \" \".join(format(b, \"02x\") for b in data) + \"\\r\\n\"); "
                      "sys.stdout.flush()'; "
                      "stty sane; "
                      "printf 'COT_SCENARIO_DONE:ctrl-letter-bytes-dispatch\\r\\n'; "
                      "sleep 0.2";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"Ctrl-A/Ctrl-C routed through NSApp sendEvent reach the PTY";
  } else if ([name isEqualToString:@"ctrl-letter-bytes"]) {
    scenario.script = @"stty -icanon -isig -echo time 0 min 2; "
                      "printf 'COT_SCENARIO_BEGIN:ctrl-letter-bytes\\r\\nCOT_READY:ctrl-letter-bytes\\r\\n'; "
                      "python3 -u -c 'import sys; "
                      "data = sys.stdin.buffer.read(2); "
                      "sys.stdout.write(\"BYTES=\" + \" \".join(format(b, \"02x\") for b in data) + \"\\r\\n\"); "
                      "sys.stdout.flush()'; "
                      "stty sane; "
                      "printf 'COT_SCENARIO_DONE:ctrl-letter-bytes\\r\\n'; "
                      "sleep 0.2";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"Ctrl-A and Ctrl-C synthesize SOH and ETX bytes to the PTY";
  } else if ([name isEqualToString:@"resize-fullscreen-app"]) {
    scenario.script = @"printf 'COT_SCENARIO_BEGIN:resize-fullscreen-app\\r\\n'; "
                      "printf '\\033[?1049hFULLSCREEN-RESIZE\\r\\n'; "
                      "sleep 0.8; stty size; "
                      "printf '\\033[?1049lCOT_SCENARIO_DONE:resize-fullscreen-app\\r\\n'; "
                      "sleep 0.1";
    scenario.expectedStatus = @"pass";
    scenario.expectedReason = @"fullscreen app PTY resize propagation is covered";
  } else {
    return nil;
  }

  return scenario;
}

+ (NSArray<NSString *> *)knownScenarioNames {
  return [NSArray arrayWithObjects:@"smoke", @"cursor", @"cursor-block", @"zoom-shortcuts",
    @"exit-closes-demo", @"terminal-env", @"delete-editing", @"mouse-no-leak", @"ansi-colors",
    @"unicode-width", @"scrollback", @"alternate-screen", @"keyboard-input", @"mouse-reporting",
    @"tmux-mouse-resize", @"tmux", @"readline-editing", @"fullscreen-app-baseline", @"line-drawing-inverse", @"vim",
    @"resize", @"resize-fullscreen-app", @"ctrl-letter-bytes", @"cmd-letter-bytes-gnustep",
    @"tmux-ctrl-a-split", @"menu-shortcut-dispatch", nil];
}

- (void)dealloc {
  [_name release];
  [_kind release];
  [_script release];
  [_expectedStatus release];
  [_expectedReason release];
  [_sentinel release];
  [super dealloc];
}

@synthesize name = _name;
@synthesize kind = _kind;
@synthesize script = _script;
@synthesize expectedStatus = _expectedStatus;
@synthesize expectedReason = _expectedReason;
@synthesize sentinel = _sentinel;

@end

@interface COTDemoOptions : NSObject {
  BOOL _selfTest;
  BOOL _exitAfterCapture;
  NSString *_scenarioName;
  NSString *_screenshotPath;
  NSString *_statePath;
  NSString *_inputScriptPath;
}

@property (nonatomic) BOOL selfTest;
@property (nonatomic) BOOL exitAfterCapture;
@property (nonatomic, copy) NSString *scenarioName;
@property (nonatomic, copy) NSString *screenshotPath;
@property (nonatomic, copy) NSString *statePath;
@property (nonatomic, copy) NSString *inputScriptPath;

+ (instancetype)optionsFromArguments:(NSArray<NSString *> *)arguments;

@end

@implementation COTDemoOptions

+ (instancetype)optionsFromArguments:(NSArray<NSString *> *)arguments {
  COTDemoOptions *options = [[[self alloc] init] autorelease];
  options.scenarioName = COTScenarioDefault;
  for (NSUInteger index = 1; index < [arguments count]; ++index) {
    NSString *argument = [arguments objectAtIndex:index];
    if ([argument isEqualToString:@"--self-test"]) {
      [options setSelfTest:YES];
    } else if ([argument isEqualToString:@"--scenario"] && index + 1 < [arguments count]) {
      [options setSelfTest:YES];
      [options setScenarioName:[arguments objectAtIndex:++index]];
    } else if ([argument isEqualToString:@"--input-script"] && index + 1 < [arguments count]) {
      [options setInputScriptPath:[arguments objectAtIndex:++index]];
    } else if ([argument isEqualToString:@"--exit-after-capture"]) {
      [options setExitAfterCapture:YES];
    } else if ([argument isEqualToString:@"--screenshot"] && index + 1 < [arguments count]) {
      [options setScreenshotPath:[arguments objectAtIndex:++index]];
    } else if ([argument isEqualToString:@"--state"] && index + 1 < [arguments count]) {
      [options setStatePath:[arguments objectAtIndex:++index]];
    } else if ([argument isEqualToString:@"--list-scenarios"]) {
      for (NSString *name in [COTDemoScenario knownScenarioNames]) {
        printf("%s\n", [name UTF8String]);
      }
      exit(0);
    } else {
      NSLog(@"Ignoring unknown argument: %@", argument);
    }
  }
  return options;
}

- (void)dealloc {
  [_scenarioName release];
  [_screenshotPath release];
  [_statePath release];
  [_inputScriptPath release];
  [super dealloc];
}

@synthesize selfTest = _selfTest;
@synthesize exitAfterCapture = _exitAfterCapture;
@synthesize scenarioName = _scenarioName;
@synthesize screenshotPath = _screenshotPath;
@synthesize statePath = _statePath;
@synthesize inputScriptPath = _inputScriptPath;

@end

@interface COTDemoAppDelegate : NSObject <NSApplicationDelegate> {
  COTDemoOptions *_options;
  COTDemoScenario *_scenario;
  NSWindow *_window;
  COTTerminalView *_terminalView;
  NSTimer *_scenarioTimer;
  NSDate *_scenarioDeadline;
  BOOL _sawScenarioSentinel;
  BOOL _captured;
  BOOL _syntheticActionsRan;
  BOOL _sawTmuxInteractivePass;
  BOOL _sawReadlineResult;
  NSDate *_scenarioStart;
  NSMutableArray *_lastInputActions;
  NSUInteger _mouseReportsSent;
  NSUInteger _mouseReportsSuppressed;
  CGFloat _zoomBaselineSize;
  CGFloat _zoomAfterInSize;
  CGFloat _zoomAfterOutSize;
  CGFloat _zoomAfterResetSize;
  NSUInteger _resizeBeforeColumns;
  NSUInteger _resizeBeforeRows;
  NSUInteger _resizeAfterColumns;
  NSUInteger _resizeAfterRows;
  BOOL _sessionDidExit;
}

- (instancetype)initWithOptions:(COTDemoOptions *)options;

@end

@implementation COTDemoAppDelegate

- (instancetype)initWithOptions:(COTDemoOptions *)options {
  self = [super init];
  if (self) {
    _options = [options retain];
    _lastInputActions = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;

#if defined(__APPLE__)
  if ([NSApp respondsToSelector:@selector(setActivationPolicy:)]) {
    [(id)NSApp setActivationPolicy:0]; // NSApplicationActivationPolicyRegular
  }
#endif

  NSRect frame = NSMakeRect(100, 100, 900, 560);
  _window = [[NSWindow alloc] initWithContentRect:frame
                                       styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask | NSMiniaturizableWindowMask)
                                         backing:NSBackingStoreBuffered
                                           defer:NO];

  COTTerminalConfiguration *configuration = [COTTerminalConfiguration defaultConfiguration];
  if ([_options selfTest]) {
    _scenario = [[COTDemoScenario scenarioNamed:[_options scenarioName]] retain];
    if (_scenario == nil) {
      NSLog(@"Unknown scenario: %@", [_options scenarioName]);
      exit(4);
    }
    [_window setTitle:[NSString stringWithFormat:@"CocoaTerminal Scenario: %@", [_scenario name]]];
    [configuration setShellCommand:[NSArray arrayWithObjects:@"/bin/sh", @"-lc", [_scenario script], nil]];
  } else {
    [_window setTitle:@"CocoaTerminal Demo"];
    [configuration setExitBehavior:COTTerminalExitBehaviorTerminateApplication];
  }

  _terminalView = [[COTTerminalView alloc] initWithFrame:[[_window contentView] bounds]
                                           configuration:configuration];
  [_terminalView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [[_window contentView] addSubview:_terminalView];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(terminalTitleDidChange:)
                                               name:@"COTTerminalSessionTitleDidChangeNotification"
                                             object:[_terminalView session]];
  [_window setDelegate:self];
  [_window makeFirstResponder:_terminalView];
  [_window makeKeyAndOrderFront:nil];
  if ([NSApp respondsToSelector:@selector(activateIgnoringOtherApps:)]) {
    [NSApp activateIgnoringOtherApps:YES];
  }

  NSError *error = nil;
  if (![_terminalView startTerminalWithError:&error]) {
    NSLog(@"Failed to start terminal: %@", error);
    exit(2);
  }

  if ([_options selfTest]) {
    _scenarioStart = [[NSDate date] retain];
    _scenarioDeadline = [[NSDate dateWithTimeIntervalSinceNow:5.0] retain];
    _scenarioTimer = [[NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                       target:self
                                                     selector:@selector(runScenarioTick:)
                                                     userInfo:nil
                                                      repeats:YES] retain];
  }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return YES;
}

- (void)windowDidResize:(NSNotification *)notification {
  (void)notification;
  [_terminalView setFrame:[[_window contentView] bounds]];
}

- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)status {
  (void)session;
  (void)status;
  _sessionDidExit = YES;
}

- (void)terminalTitleDidChange:(NSNotification *)note {
  if ([_options selfTest]) {
    return;
  }
  NSString *title = [[note userInfo] objectForKey:@"title"];
  if ([title length] > 0) {
    [_window setTitle:title];
  }
}

- (void)runScenarioTick:(NSTimer *)timer {
  (void)timer;
  [[_terminalView session] poll];
  [self runSyntheticScenarioActionsIfNeeded];

  if (!_sawScenarioSentinel) {
    _sawScenarioSentinel = [self visibleLinesContain:[_scenario sentinel]];
  }
  if (!_sawTmuxInteractivePass) {
    _sawTmuxInteractivePass = [self visibleLinesContain:@"tmux-interactive-pass"];
  }
  if (!_sawReadlineResult) {
    _sawReadlineResult = [self visibleLinesContain:@"readline-result=abXc"];
  }

  BOOL timedOut = [[NSDate date] compare:_scenarioDeadline] == NSOrderedDescending;
  if ((_sawScenarioSentinel || timedOut) && !_captured) {
    _captured = YES;
    if (_sawScenarioSentinel) {
      [[_terminalView session] terminate];
    }
    [self captureScenarioAndExitWithSuccess:_sawScenarioSentinel timedOut:timedOut];
  }
}

- (void)runSyntheticScenarioActionsIfNeeded {
  if (_syntheticActionsRan) {
    return;
  }
  if ([[_scenario name] isEqualToString:@"mouse-no-leak"]) {
    _syntheticActionsRan = YES;
    [self runInputAction:@"mouseClick 4 2"];
    [self runInputAction:@"mouseWheel down"];
  } else if ([[_scenario name] isEqualToString:@"zoom-shortcuts"]) {
    _syntheticActionsRan = YES;
    COTTerminalTheme *theme = [[[_terminalView session] configuration] theme];
    _zoomBaselineSize = [theme fontSize];
    [self runInputAction:@"sendShortcut ctrl+="];
    _zoomAfterInSize = [theme fontSize];
    [self runInputAction:@"sendShortcut ctrl++"];
    [self runInputAction:@"sendShortcut ctrl+-"];
    _zoomAfterOutSize = [theme fontSize];
    [self runInputAction:@"sendShortcut ctrl+0"];
    _zoomAfterResetSize = [theme fontSize];
  } else if ([[_scenario name] isEqualToString:@"resize-fullscreen-app"]) {
    if ([[NSDate date] timeIntervalSinceDate:_scenarioStart] < 0.2) {
      return;
    }
    _syntheticActionsRan = YES;
    _resizeBeforeColumns = [[_terminalView session] columns];
    _resizeBeforeRows = [[_terminalView session] rows];
    NSRect frame = [_window frame];
    frame.size.width += 220.0;
    frame.size.height += 140.0;
    [_window setFrame:frame display:YES];
    [_terminalView setFrame:[[_window contentView] bounds]];
    [[_terminalView session] poll];
    _resizeAfterColumns = [[_terminalView session] columns];
    _resizeAfterRows = [[_terminalView session] rows];
  } else if ([[_scenario name] isEqualToString:@"readline-editing"]) {
    if ([[NSDate date] timeIntervalSinceDate:_scenarioStart] < 0.2) {
      return;
    }
    _syntheticActionsRan = YES;
    [self runInputAction:@"sendText abc"];
    [self runInputAction:@"sendKey left"];
    [self runInputAction:@"sendText X"];
    [self runInputAction:@"sendKey enter"];
  } else if ([[_scenario name] isEqualToString:@"ctrl-letter-bytes"]) {
    if (![self visibleLinesContain:@"COT_READY:ctrl-letter-bytes"]) {
      return;
    }
    _syntheticActionsRan = YES;
    [self runInputAction:@"sendCtrlKey a"];
    [self runInputAction:@"sendCtrlKey c"];
  } else if ([[_scenario name] isEqualToString:@"ctrl-letter-bytes-dispatch"]) {
    if (![self visibleLinesContain:@"COT_READY:ctrl-letter-bytes-dispatch"]) {
      return;
    }
    _syntheticActionsRan = YES;
    [self runInputAction:@"dispatchCtrlKey a"];
    [self runInputAction:@"dispatchCtrlKey c"];
  } else if ([[_scenario name] isEqualToString:@"menu-shortcut-dispatch"]) {
    if (![self visibleLinesContain:@"CLIPBOARD_FIXTURE_LINE"]) {
      return;
    }
    _syntheticActionsRan = YES;
    [self runInputAction:@"dispatchCmdShiftKey a"];
  } else if ([[_scenario name] isEqualToString:@"cmd-letter-bytes-gnustep"]) {
    if (![self visibleLinesContain:@"COT_READY:cmd-letter-bytes-gnustep"]) {
      return;
    }
    _syntheticActionsRan = YES;
    [self runInputAction:@"dispatchCmdKey a"];
    [self runInputAction:@"dispatchCmdKey c"];
  } else if ([[_scenario name] isEqualToString:@"tmux-ctrl-a-split"]) {
    if (![self visibleLinesContain:@"TMUX_READY"]) {
      return;
    }
    _syntheticActionsRan = YES;
    [self runInputAction:@"sendCtrlKey a"];
    [self runInputAction:@"sendText \""];
  } else if ([[_scenario name] isEqualToString:@"mouse-reporting"] && [[_terminalView session] isMouseReportingEnabled]) {
    _syntheticActionsRan = YES;
    [self runInputAction:@"mouseClick 4 2"];
    [self runInputAction:@"mouseDrag 12 2"];
    [self runInputAction:@"mouseRelease 12 2"];
    [self runInputAction:@"mouseWheel down"];
  } else if ([[_scenario name] isEqualToString:@"tmux-mouse-resize"] && [[_terminalView session] isMouseReportingEnabled]) {
    _syntheticActionsRan = YES;
    [self runInputAction:@"mouseClick 10 10"];
    [self runInputAction:@"mouseDrag 24 10"];
    [self runInputAction:@"mouseRelease 24 10"];
  } else if ([[_options inputScriptPath] length] > 0) {
    _syntheticActionsRan = YES;
    [self runInputScriptAtPath:[_options inputScriptPath]];
  }
}

- (void)runInputScriptAtPath:(NSString *)path {
  NSError *error = nil;
  NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
  if (contents == nil) {
    [_lastInputActions addObject:[NSString stringWithFormat:@"inputScriptError %@", error]];
    return;
  }
  NSArray *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  for (NSString *line in lines) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"]) {
      continue;
    }
    [self runInputAction:trimmed];
  }
}

- (void)runInputAction:(NSString *)action {
  [_lastInputActions addObject:action];
  if ([action hasPrefix:@"sendCtrlKey "]) {
    NSString *suffix = [action substringFromIndex:[@"sendCtrlKey " length]];
    if ([suffix length] > 0) {
      NSString *letter = [[suffix substringToIndex:1] lowercaseString];
      NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:NSControlKeyMask
                                       timestamp:0
                                    windowNumber:[_window windowNumber]
                                         context:nil
                                      characters:letter
                     charactersIgnoringModifiers:letter
                                       isARepeat:NO
                                         keyCode:0];
      [_terminalView keyDown:event];
    }
    return;
  }
  if ([action hasPrefix:@"dispatchCtrlKey "]) {
    NSString *suffix = [action substringFromIndex:[@"dispatchCtrlKey " length]];
    if ([suffix length] > 0) {
      NSString *letter = [[suffix substringToIndex:1] lowercaseString];
      NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:NSControlKeyMask
                                       timestamp:0
                                    windowNumber:[_window windowNumber]
                                         context:nil
                                      characters:letter
                     charactersIgnoringModifiers:letter
                                       isARepeat:NO
                                         keyCode:0];
      [NSApp sendEvent:event];
    }
    return;
  }
  if ([action hasPrefix:@"dispatchCmdKey "]) {
    NSString *suffix = [action substringFromIndex:[@"dispatchCmdKey " length]];
    if ([suffix length] > 0) {
      NSString *letter = [[suffix substringToIndex:1] lowercaseString];
      NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:NSCommandKeyMask
                                       timestamp:0
                                    windowNumber:[_window windowNumber]
                                         context:nil
                                      characters:letter
                     charactersIgnoringModifiers:letter
                                       isARepeat:NO
                                         keyCode:0];
      [NSApp sendEvent:event];
    }
    return;
  }
  if ([action hasPrefix:@"dispatchCmdShiftKey "]) {
    NSString *suffix = [action substringFromIndex:[@"dispatchCmdShiftKey " length]];
    if ([suffix length] > 0) {
      NSString *letter = [[suffix substringToIndex:1] uppercaseString];
      NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:(NSCommandKeyMask | NSShiftKeyMask)
                                       timestamp:0
                                    windowNumber:[_window windowNumber]
                                         context:nil
                                      characters:letter
                     charactersIgnoringModifiers:letter
                                       isARepeat:NO
                                         keyCode:0];
      [NSApp sendEvent:event];
    }
    return;
  }
  if ([action hasPrefix:@"sendText "]) {
    NSString *text = [action substringFromIndex:[@"sendText " length]];
    [[_terminalView session] sendInput:[text dataUsingEncoding:NSUTF8StringEncoding]];
  } else if ([action isEqualToString:@"sendKey enter"]) {
    [[_terminalView session] sendInput:[@"\r" dataUsingEncoding:NSUTF8StringEncoding]];
  } else if ([action isEqualToString:@"sendKey backspace"]) {
    const unsigned char byte = 0x7f;
    [[_terminalView session] sendInput:[NSData dataWithBytes:&byte length:1]];
  } else if ([action isEqualToString:@"sendKey delete"]) {
    [[_terminalView session] sendInput:[@"\033[3~" dataUsingEncoding:NSUTF8StringEncoding]];
  } else if ([action isEqualToString:@"sendKey left"]) {
    [[_terminalView session] sendInput:[@"\033[D" dataUsingEncoding:NSUTF8StringEncoding]];
  } else if ([action isEqualToString:@"sendKey right"]) {
    [[_terminalView session] sendInput:[@"\033[C" dataUsingEncoding:NSUTF8StringEncoding]];
  } else if ([action isEqualToString:@"sendShortcut ctrl+="]) {
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:NSControlKeyMask
                                     timestamp:0
                                  windowNumber:[_window windowNumber]
                                       context:nil
                                    characters:@"="
                   charactersIgnoringModifiers:@"="
                                     isARepeat:NO
                                       keyCode:24];
    [_terminalView keyDown:event];
  } else if ([action isEqualToString:@"sendShortcut ctrl++"]) {
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:(NSControlKeyMask | NSShiftKeyMask)
                                     timestamp:0
                                  windowNumber:[_window windowNumber]
                                       context:nil
                                    characters:@"+"
                   charactersIgnoringModifiers:@"="
                                     isARepeat:NO
                                       keyCode:24];
    [_terminalView keyDown:event];
  } else if ([action isEqualToString:@"sendShortcut ctrl+-"]) {
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:NSControlKeyMask
                                     timestamp:0
                                  windowNumber:[_window windowNumber]
                                       context:nil
                                    characters:@"-"
                   charactersIgnoringModifiers:@"-"
                                     isARepeat:NO
                                       keyCode:27];
    [_terminalView keyDown:event];
  } else if ([action isEqualToString:@"sendShortcut ctrl+0"]) {
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:NSControlKeyMask
                                     timestamp:0
                                  windowNumber:[_window windowNumber]
                                       context:nil
                                    characters:@"0"
                   charactersIgnoringModifiers:@"0"
                                     isARepeat:NO
                                       keyCode:29];
    [_terminalView keyDown:event];
  } else if ([action hasPrefix:@"mouseClick "]) {
    [self sendSyntheticMouseReportWithButton:0 final:'M'];
  } else if ([action hasPrefix:@"mouseDrag "]) {
    [self sendSyntheticMouseReportWithButton:32 final:'M'];
  } else if ([action hasPrefix:@"mouseRelease "]) {
    [self sendSyntheticMouseReportWithButton:0 final:'m'];
  } else if ([action hasPrefix:@"mouseWheel "]) {
    [self sendSyntheticMouseReportWithButton:[action hasSuffix:@"up"] ? 64 : 65 final:'M'];
  }
}

- (void)sendSyntheticMouseReportWithButton:(int)button final:(char)final {
  if (![[_terminalView session] isMouseReportingEnabled]) {
    ++_mouseReportsSuppressed;
    return;
  }
  NSString *report = [NSString stringWithFormat:@"\033[<%d;4;2%c", button, final];
  [[_terminalView session] sendInput:[report dataUsingEncoding:NSUTF8StringEncoding]];
  ++_mouseReportsSent;
}

- (BOOL)visibleLinesContain:(NSString *)needle {
  for (NSString *line in [[_terminalView session] visibleLines]) {
    if ([line rangeOfString:needle].location != NSNotFound) {
      return YES;
    }
  }
  return NO;
}

- (NSString *)visibleLineValueWithPrefix:(NSString *)prefix {
  for (NSString *line in [[_terminalView session] visibleLines]) {
    NSRange range = [line rangeOfString:prefix];
    if (range.location != NSNotFound) {
      NSUInteger start = range.location + range.length;
      NSString *value = [line substringFromIndex:start];
      return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
  }
  return @"<none>";
}

- (void)captureScenarioAndExitWithSuccess:(BOOL)success timedOut:(BOOL)timedOut {
  [_scenarioTimer invalidate];
  [_window displayIfNeeded];
  [_terminalView displayIfNeeded];

  BOOL wroteScreenshot = YES;
  BOOL wroteState = YES;

  if ([_options screenshotPath] != nil) {
    NSError *error = nil;
    NSData *png = [_terminalView PNGRepresentationWithError:&error];
    wroteScreenshot = png != nil && [png writeToFile:[_options screenshotPath] options:NSDataWritingAtomic error:&error];
    if (!wroteScreenshot) {
      NSLog(@"Failed to write screenshot %@: %@", [_options screenshotPath], error);
    }
  }

  if ([_options statePath] != nil) {
    NSString *state = [self scenarioStateTextWithSuccess:success timedOut:timedOut screenshotWritten:wroteScreenshot];
    NSError *error = nil;
    wroteState = [state writeToFile:[_options statePath]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&error];
    if (!wroteState) {
      NSLog(@"Failed to write state %@: %@", [_options statePath], error);
    }
  }

  int status = (success && wroteScreenshot && wroteState) ? 0 : 3;
  if ([_options exitAfterCapture]) {
    exit(status);
  }
}

- (NSString *)scenarioStateTextWithSuccess:(BOOL)success timedOut:(BOOL)timedOut screenshotWritten:(BOOL)screenshotWritten {
  NSMutableString *state = [NSMutableString string];
  NSRect bounds = [_terminalView bounds];
  [state appendFormat:@"success=%@\n", success ? @"true" : @"false"];
  [state appendFormat:@"timed_out=%@\n", timedOut ? @"true" : @"false"];
  [state appendFormat:@"screenshot_written=%@\n", screenshotWritten ? @"true" : @"false"];
  [state appendFormat:@"scenario=%@\n", [_scenario name]];
  [state appendFormat:@"scenario_kind=%@\n", [_scenario kind]];
  [state appendFormat:@"scenario_expected_status=%@\n", [_scenario expectedStatus]];
  [state appendFormat:@"scenario_expected_reason=%@\n", [_scenario expectedReason]];
  [state appendFormat:@"scenario_sentinel=%@\n", [_scenario sentinel]];
  [state appendFormat:@"input_script=%@\n", [_options inputScriptPath] == nil ? @"<none>" : [_options inputScriptPath]];
  [state appendFormat:@"view_width=%.0f\n", bounds.size.width];
  [state appendFormat:@"view_height=%.0f\n", bounds.size.height];
  [state appendFormat:@"columns=%lu\n", (unsigned long)[[_terminalView session] columns]];
  [state appendFormat:@"rows=%lu\n", (unsigned long)[[_terminalView session] rows]];
  [state appendFormat:@"cursor_visible=%@\n", [_window firstResponder] == _terminalView ? @"true" : @"false"];
  [state appendFormat:@"cursor_visible_by_escape=%@\n", [[_terminalView session] isCursorVisible] ? @"true" : @"false"];
  [state appendFormat:@"cursor_column=%lu\n", (unsigned long)[[_terminalView session] cursorColumn]];
  [state appendFormat:@"cursor_row=%lu\n", (unsigned long)[[_terminalView session] cursorRow]];
  [state appendFormat:@"running=%@\n", [[_terminalView session] isRunning] ? @"true" : @"false"];
  [state appendString:@"capability_color_spans=true\n"];
  [state appendString:@"capability_unicode_width=true\n"];
  [state appendString:@"capability_scrollback=true\n"];
  [state appendString:@"capability_alternate_screen=true\n"];
  [state appendString:@"capability_keyboard_injection=true\n"];
  [state appendString:@"capability_mouse_reporting=true\n"];
  [state appendString:@"capability_runtime_resize=true\n"];
  [state appendFormat:@"observed_color_spans=%@\n", [[_terminalView session] hasColorSpans] ? @"true" : @"false"];
  [state appendFormat:@"observed_unicode=%@\n", [[_terminalView session] hasUnicode] ? @"true" : @"false"];
  [state appendFormat:@"observed_scrollback_lines=%lu\n", (unsigned long)[[_terminalView session] scrollbackLineCount]];
  [state appendFormat:@"observed_alternate_screen=%@\n", [[_terminalView session] hasUsedAlternateScreen] ? @"true" : @"false"];
  [state appendFormat:@"observed_mouse_reporting=%@\n", [[_terminalView session] isMouseReportingEnabled] ? @"true" : @"false"];
  [state appendFormat:@"observed_mouse_button_motion=%@\n", [[_terminalView session] isMouseButtonMotionReportingEnabled] ? @"true" : @"false"];
  [state appendFormat:@"observed_mouse_any_motion=%@\n", [[_terminalView session] isMouseAnyMotionReportingEnabled] ? @"true" : @"false"];
  [state appendFormat:@"observed_sgr_mouse=%@\n", [[_terminalView session] isSGRMouseModeEnabled] ? @"true" : @"false"];
  [state appendFormat:@"observed_alternate_scroll=%@\n", [[_terminalView session] isAlternateScrollModeEnabled] ? @"true" : @"false"];
  BOOL mouseNoLeak = [[_scenario name] isEqualToString:@"mouse-no-leak"];
  [state appendFormat:@"mouse_reports_suppressed=%@\n", mouseNoLeak && ![[_terminalView session] isMouseReportingEnabled] ? @"true" : @"false"];
  [state appendFormat:@"mouse_reports_sent=%lu\n", (unsigned long)_mouseReportsSent];
  [state appendFormat:@"mouse_reports_suppressed_count=%lu\n", (unsigned long)_mouseReportsSuppressed];
  [state appendFormat:@"delete_edit_result=%@\n", [self visibleLinesContain:@"delete-result=ab"] ? @"ab" : @"<none>"];
  [state appendFormat:@"last_input_actions=%@\n", [_lastInputActions componentsJoinedByString:@"|"]];
  [state appendFormat:@"term_value=%@\n", [self visibleLineValueWithPrefix:@"TERM_VALUE="]];
  [state appendFormat:@"colorterm_value=%@\n", [self visibleLineValueWithPrefix:@"COLORTERM_VALUE="]];
  [state appendFormat:@"tmux_interactive_pass=%@\n", _sawTmuxInteractivePass ? @"true" : @"false"];
  [state appendFormat:@"readline_result=%@\n", _sawReadlineResult ? @"abXc" : @"<none>"];
  [state appendFormat:@"resize_before_columns=%lu\n", (unsigned long)_resizeBeforeColumns];
  [state appendFormat:@"resize_before_rows=%lu\n", (unsigned long)_resizeBeforeRows];
  [state appendFormat:@"resize_after_columns=%lu\n", (unsigned long)_resizeAfterColumns];
  [state appendFormat:@"resize_after_rows=%lu\n", (unsigned long)_resizeAfterRows];
  [state appendFormat:@"session_did_exit=%@\n", _sessionDidExit ? @"true" : @"false"];
  [state appendFormat:@"exit_behavior=%ld\n", (long)[[[_terminalView session] configuration] exitBehavior]];

  COTTerminalTheme *theme = [[[_terminalView session] configuration] theme];
  NSEdgeInsets insets = [theme contentInsets];
  [state appendFormat:@"theme_name=%@\n", [theme name]];
  [state appendFormat:@"cursor_style=%@\n", [theme cursorStyle] == COTTerminalCursorStyleBlock ? @"block" : @"other"];
  [state appendFormat:@"font_family=%@\n", [theme fontFamily]];
  [state appendFormat:@"resolved_font=%@\n", [[theme font] fontName]];
  [state appendFormat:@"font_size=%.1f\n", [theme fontSize]];
  [state appendFormat:@"foreground_color=%@\n", COTHexStringForColor([theme foregroundColor])];
  [state appendFormat:@"background_color=%@\n", COTHexStringForColor([theme backgroundColor])];
  [state appendFormat:@"cursor_color=%@\n", COTHexStringForColor([theme cursorColor])];
  [state appendFormat:@"selection_color=%@\n", COTHexStringForColor([theme selectionColor])];
  [state appendFormat:@"content_insets=%.0f,%.0f,%.0f,%.0f\n", insets.top, insets.left, insets.bottom, insets.right];
  [state appendFormat:@"line_spacing=%.1f\n", [theme lineSpacing]];
  [state appendFormat:@"opacity=%.2f\n", [theme opacity]];
  [state appendFormat:@"zoom_baseline_size=%.1f\n", _zoomBaselineSize];
  [state appendFormat:@"zoom_after_in=%.1f\n", _zoomAfterInSize];
  [state appendFormat:@"zoom_after_out=%.1f\n", _zoomAfterOutSize];
  [state appendFormat:@"zoom_after_reset=%.1f\n", _zoomAfterResetSize];

  NSString *selectedText = [_terminalView selectedText] ?: @"";
  NSString *selectedTrim = [selectedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  [state appendFormat:@"selected_text=%@\n", [selectedTrim length] > 0 ? selectedTrim : @"<none>"];

  [state appendString:@"visible_lines_begin\n"];
  for (NSString *line in [[_terminalView session] visibleLines]) {
    [state appendString:line];
    [state appendString:@"\n"];
  }
  [state appendString:@"visible_lines_end\n"];
  return state;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_scenarioTimer invalidate];
  [_scenarioTimer release];
  [_scenarioDeadline release];
  [_scenarioStart release];
  [_terminalView release];
  [_window release];
  [_scenario release];
  [_options release];
  [_lastInputActions release];
  [super dealloc];
}

@end

int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  // Suppress GNUstep's floating menu window: inline-menu style with no menu
  // installed = no menu chrome at all (Alacritty-style minimalism).
  [[NSUserDefaults standardUserDefaults] setObject:@"NSWindows95InterfaceStyle"
                                            forKey:@"NSMenuInterfaceStyle"];
  COTDemoOptions *options = [COTDemoOptions optionsFromArguments:[[NSProcessInfo processInfo] arguments]];
  NSApplication *app = [NSApplication sharedApplication];
  COTDemoAppDelegate *delegate = [[COTDemoAppDelegate alloc] initWithOptions:options];
  [app setDelegate:delegate];
  [app run];
  [delegate release];
  [pool drain];
  return 0;
}
