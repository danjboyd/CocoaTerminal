// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTPlatform.h>
#import <CocoaTerminal/COTTerminalSession.h>

@class COTTerminalConfiguration;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const COTTerminalViewDidExitNotification;
extern NSString *const COTTerminalExitStatusUserInfoKey;

@interface COTTerminalView : NSView <COTTerminalDelegate>

@property (nonatomic, readonly, retain) COTTerminalSession *session;

- (instancetype)initWithFrame:(NSRect)frameRect configuration:(COTTerminalConfiguration *)configuration;
- (instancetype)initWithFrame:(NSRect)frameRect;
- (nullable instancetype)initWithCoder:(NSCoder *)coder;

- (BOOL)startTerminalWithError:(NSError **)error;
- (nullable NSData *)PNGRepresentationWithError:(NSError **)error;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
- (NSString *)selectedText;
- (void)copySelection;
- (void)pasteFromClipboard;
- (void)clearSelection;
- (void)selectAll;
- (NSDictionary *)performanceSnapshot;

@end

NS_ASSUME_NONNULL_END
