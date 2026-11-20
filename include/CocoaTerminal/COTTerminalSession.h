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
typedef NS_ENUM(NSInteger, COTTerminalEnqueueResult) {
  COTTerminalEnqueueAccepted = 0,
  COTTerminalEnqueueBackpressured = 1,
  COTTerminalEnqueueClosed = 2,
  COTTerminalEnqueueFailed = 3,
};

@protocol COTTerminalDelegate <NSObject>
@optional
- (void)terminalSession:(COTTerminalSession *)session didEncounterTransportError:(NSString *)message;
- (void)terminalSessionDidUpdateScreen:(COTTerminalSession *)session;
/// A command the shell marked as finished (OSC 133 D), on the main thread.
- (void)terminalSession:(COTTerminalSession *)session didFinishCommand:(NSDictionary *)command;
// Raw wait status, delivered once, on the main queue, only when the child was
// actually reaped. Final output read before the reap is ingested first.
- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)status;
// The child's status could not be obtained (e.g. ECHILD). No status is invented.
- (void)terminalSession:(COTTerminalSession *)session didLoseChildWithError:(int)errorNumber;
- (void)terminalSessionDidRequestBell:(COTTerminalSession *)session;
- (void)terminalSession:(COTTerminalSession *)session didChangeTitle:(NSString *)title;
@end

// Threading: every delegate callback is delivered on the main queue
// (didExitWithStatus: and didLoseChildWithError: included, since patch B).
@interface COTTerminalSession : NSObject

@property (nonatomic, readonly, copy) COTTerminalConfiguration *configuration;
@property (nonatomic, assign, nullable) id<COTTerminalDelegate> delegate;
// YES from a successful start until the child exits, is lost, or terminate.
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger columns;
@property (nonatomic, readonly) NSUInteger rows;
@property (nonatomic, readonly) NSUInteger cursorColumn;
@property (nonatomic, readonly) NSUInteger cursorRow;
@property (nonatomic, readonly, getter=isCursorVisible) BOOL cursorVisible;

// Immutable lifetime policies. Observe denies transport writes AND clipboard
// protocols/local copy/paste; selection and scrolling remain local.
@property (nonatomic, readonly) BOOL allowsInput;
@property (nonatomic, readonly) BOOL allowsLocalCopy;
@property (nonatomic, readonly) BOOL fixedGrid;
// Output-only ingestion for an Observe session without starting a child.
- (void)ingestOutputData:(NSData *)data;

- (nullable instancetype)initWithConfiguration:(COTTerminalConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Refused until the previous run's cleanup is complete (fd closed after its
// reader and writer cancelled, child reaped or reported lost).
- (BOOL)startWithError:(NSError **)error;
// SIGHUP once to the direct child (no group signal, no escalation), then retire
// the transport. isRunning becomes NO immediately; the child stays owned and is
// reaped in the background, and didExitWithStatus: still follows when it is.
// isCleanupComplete says when the fd is closed and the child reaped.
// On Windows -terminate ends the ConPTY process itself and reports no exit.
- (void)terminate;
// Compatibility: read what is ready and reap once, through the single reader.
// Synchronous on the terminal queue; never call it from that queue (from a
// delegate or parser callback running there): such a call is refused and
// reported in transportError.
- (void)poll;
// YES when no fd, child or pending cancellation remains from the last run.
@property (nonatomic, readonly, getter=isCleanupComplete) BOOL cleanupComplete;
// App quit: terminate every live session, then wait up to `timeout` for their
// cleanup. Returns how many are still stopping (a child ignoring SIGHUP); those
// are reported, never killed. Never waits past the timeout.
+ (NSUInteger)shutdownAllSessionsWithTimeout:(NSTimeInterval)timeout;
- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows;
// Accepted = whole immutable transaction admitted locally, not child execution.
// Total pending limit 1 MiB. Backpressure rejects the whole transaction. No retry
// or replay is automatic. The legacy wrapper exposes refusal in transportError.
- (COTTerminalEnqueueResult)trySendInput:(NSData *)data;
@property (nonatomic, readonly, copy, nullable) NSString *transportError;
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
/// Every line held: the scrollback (oldest first), then the screen's rows. Lines in -findText: are numbered this way.
- (NSUInteger)lineCount;
/// Searches the scrollback and the screen for text. Forward, it finds the first match at or after (line, column);
/// backward, the last one before it; both wrap round, and a line of -lineCount or more means "from the end". YES with
/// the match's line, first cell column and width in cells. A match lies within one line; case is ignored for ASCII
/// letters when ignoreCase is YES.
- (BOOL)findText:(NSString *)text
        fromLine:(NSUInteger)line
          column:(NSUInteger)column
       backwards:(BOOL)backwards
      ignoreCase:(BOOL)ignoreCase
       matchLine:(nullable NSUInteger *)matchLine
     matchColumn:(nullable NSUInteger *)matchColumn
      matchWidth:(nullable NSUInteger *)matchWidth;
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
