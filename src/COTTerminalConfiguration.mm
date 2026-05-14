// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTTerminalConfiguration.h>
#import <CocoaTerminal/COTTerminalTheme.h>

@implementation COTTerminalConfiguration

+ (instancetype)defaultConfiguration {
  return [[[self alloc] init] autorelease];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    NSString *shell = [[[NSProcessInfo processInfo] environment] objectForKey:@"SHELL"];
    if ([shell length] == 0) {
#if defined(_WIN32)
      shell = @"powershell.exe";
#else
      shell = @"/bin/sh";
#endif
    }

    _terminalType = [@"xterm-256color" copy];
    _shellCommand = [[NSArray alloc] initWithObjects:shell, nil];
    NSMutableDictionary *environment = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    [environment removeObjectForKey:@"TMUX"];
    [environment removeObjectForKey:@"TMUX_PANE"];
    [environment removeObjectForKey:@"STY"];
    [environment removeObjectForKey:@"WINDOWID"];
    [environment setObject:_terminalType forKey:@"TERM"];
    [environment setObject:@"truecolor" forKey:@"COLORTERM"];
    _environment = [environment copy];
    _workingDirectory = [NSHomeDirectory() copy];
    _theme = [[COTTerminalTheme defaultTheme] retain];
    _scrollbackLineLimit = 10000;
    _keyboardCapturePolicy = COTKeyboardCapturePolicyTerminalDefault;
    _exitBehavior = COTTerminalExitBehaviorKeepOpen;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  COTTerminalConfiguration *copy = [[[self class] allocWithZone:zone] init];
  copy.shellCommand = self.shellCommand;
  copy.environment = self.environment;
  copy.workingDirectory = self.workingDirectory;
  copy.terminalType = self.terminalType;
  copy.theme = [[self.theme copy] autorelease];
  copy.scrollbackLineLimit = self.scrollbackLineLimit;
  copy.keyboardCapturePolicy = self.keyboardCapturePolicy;
  copy.exitBehavior = self.exitBehavior;
  return copy;
}

- (void)setTerminalType:(NSString *)terminalType {
  if (_terminalType != terminalType) {
    [_terminalType release];
    _terminalType = [terminalType copy];
  }
  NSMutableDictionary *environment = [NSMutableDictionary dictionaryWithDictionary:_environment];
  if ([_terminalType length] > 0) {
    [environment setObject:_terminalType forKey:@"TERM"];
  }
  [environment setObject:@"truecolor" forKey:@"COLORTERM"];
  self.environment = environment;
}

- (NSFont *)font {
  return [_theme font];
}

- (void)setFont:(NSFont *)font {
  [_theme setFont:font];
  if (font != nil) {
    [_theme setFontFamily:[font fontName]];
    [_theme setFontSize:[font pointSize]];
  }
}

- (NSColor *)foregroundColor {
  return [_theme foregroundColor];
}

- (void)setForegroundColor:(NSColor *)foregroundColor {
  [_theme setForegroundColor:foregroundColor];
}

- (NSColor *)backgroundColor {
  return [_theme backgroundColor];
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
  [_theme setBackgroundColor:backgroundColor];
}

- (void)dealloc {
  [_shellCommand release];
  [_environment release];
  [_workingDirectory release];
  [_terminalType release];
  [_theme release];
  [super dealloc];
}

@synthesize shellCommand = _shellCommand;
@synthesize environment = _environment;
@synthesize workingDirectory = _workingDirectory;
@synthesize terminalType = _terminalType;
@synthesize theme = _theme;
@synthesize scrollbackLineLimit = _scrollbackLineLimit;
@synthesize keyboardCapturePolicy = _keyboardCapturePolicy;
@synthesize exitBehavior = _exitBehavior;

@end
