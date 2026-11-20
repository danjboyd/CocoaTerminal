// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTPlatform.h>

@class COTTerminalConfiguration;
@class COTTerminalSession;

NS_ASSUME_NONNULL_BEGIN

/// Shell integration: a shell that marks its prompts and commands with OSC 133 (A prompt, B command line, C output,
/// D;status finished) lets the session find prompts and each command's output. A finished command is a dictionary
/// with these keys: the command line as typed, its output (lines joined with "\n"), its exit status (an NSNumber, -1
/// if the shell gave none), and the lines its prompt and output start on (the scrollback's oldest line is 0, the
/// screen's rows follow it). See README.md for the few lines a bash or zsh prompt needs.
extern NSString *const COTTerminalSessionCommandDidFinishNotification;  // userInfo: the finished command
extern NSString *const COTTerminalCommandTextKey;
extern NSString *const COTTerminalCommandOutputKey;
extern NSString *const COTTerminalCommandExitStatusKey;
extern NSString *const COTTerminalCommandPromptLineKey;
extern NSString *const COTTerminalCommandOutputLineKey;

@protocol COTTerminalDelegate <NSObject>
@optional
- (void)terminalSessionDidUpdateScreen:(COTTerminalSession *)session;
/// A command the shell marked as finished (OSC 133 D), on the main thread.
- (void)terminalSession:(COTTerminalSession *)session didFinishCommand:(NSDictionary *)command;
- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)status;
- (void)terminalSessionDidRequestBell:(COTTerminalSession *)session;
- (void)terminalSession:(COTTerminalSession *)session didChangeTitle:(NSString *)title;
@end

@interface COTTerminalSession : NSObject

@property (nonatomic, readonly, copy) COTTerminalConfiguration *configuration;
@property (nonatomic, assign, nullable) id<COTTerminalDelegate> delegate;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger columns;
@property (nonatomic, readonly) NSUInteger rows;
@property (nonatomic, readonly) NSUInteger cursorColumn;
@property (nonatomic, readonly) NSUInteger cursorRow;
@property (nonatomic, readonly, getter=isCursorVisible) BOOL cursorVisible;

- (instancetype)initWithConfiguration:(COTTerminalConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startWithError:(NSError **)error;
- (void)terminate;
- (void)poll;
- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows;
- (void)sendInput:(NSData *)data;
- (NSArray<NSString *> *)visibleLines;
- (NSArray<NSArray<NSDictionary *> *> *)styledVisibleRows;
- (NSUInteger)scrollbackLineCount;
/// Changes how many lines of scrollback are kept, while running. Lowering it drops the oldest lines at once (and
/// pulls a scrolled-back viewport in to what's left). Also updates the configuration's scrollbackLineLimit.
- (void)setScrollbackLineLimit:(NSUInteger)limit;
- (BOOL)isBracketedPasteEnabled;
- (BOOL)isFocusReportingEnabled;
- (NSString *)title;
- (nullable NSString *)lastClipboardWrite;
- (NSUInteger)clipboardWriteCount;
- (NSUInteger)viewportOffset;
- (NSUInteger)maxViewportOffset;
- (void)setViewportOffset:(NSUInteger)offset;
- (void)adjustViewportOffset:(NSInteger)delta;
- (void)scrollToBottom;
/// Shell integration (OSC 133): the lines prompts start on, oldest first, numbered with the scrollback first; and the
/// most recent finished command (see COTTerminalCommandTextKey and the other keys), or nil.
- (NSArray<NSNumber *> *)promptLines;
- (nullable NSDictionary *)lastFinishedCommand;
- (BOOL)isUsingAlternateScreen;
- (BOOL)hasUsedAlternateScreen;
- (BOOL)hasColorSpans;
- (BOOL)hasUnicode;
- (BOOL)isMouseReportingEnabled;
- (BOOL)isMouseButtonMotionReportingEnabled;
- (BOOL)isMouseAnyMotionReportingEnabled;
- (BOOL)isSGRMouseModeEnabled;
- (BOOL)isAlternateScrollModeEnabled;

@end

NS_ASSUME_NONNULL_END
