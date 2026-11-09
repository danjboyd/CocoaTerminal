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

// Immutable lifetime policies. Observe denies transport writes AND clipboard
// protocols/local copy/paste; selection and scrolling remain local.
@property (nonatomic, readonly) BOOL allowsInput;
@property (nonatomic, readonly) BOOL allowsLocalCopy;
@property (nonatomic, readonly) BOOL fixedGrid;
// Output-only ingestion for an Observe session without starting a child.
- (void)ingestOutputData:(NSData *)data;

- (nullable instancetype)initWithConfiguration:(COTTerminalConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startWithError:(NSError **)error;
- (void)terminate;
- (void)poll;
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
