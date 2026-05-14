// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTPlatform.h>

@class COTTerminalConfiguration;
@class COTTerminalSession;

NS_ASSUME_NONNULL_BEGIN

@protocol COTTerminalDelegate <NSObject>
@optional
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
- (BOOL)isBracketedPasteEnabled;
- (BOOL)isFocusReportingEnabled;
- (NSString *)title;
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
