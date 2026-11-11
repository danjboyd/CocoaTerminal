// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTPlatform.h>

@class COTTerminalConfiguration;
@class COTTerminalSession;

NS_ASSUME_NONNULL_BEGIN

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
// Raw wait status, delivered once, on the main queue, only when the child was
// actually reaped. Final output read before the reap is ingested first.
- (void)terminalSession:(COTTerminalSession *)session didExitWithStatus:(int)status;
// The child's status could not be obtained (e.g. ECHILD). No status is invented.
- (void)terminalSession:(COTTerminalSession *)session didLoseChildWithError:(int)errorNumber;
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
// the transport. The child stays owned and is reaped in the background.
- (void)terminate;
// Compatibility: read what is ready and reap once, through the single reader.
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
