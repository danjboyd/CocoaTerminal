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
/// Applies a theme to a view that may already be running: a copy of it becomes the session's theme and the new base
/// size for zoom (any zoom is reset). The cells are measured again, a running session is resized to fit (the program
/// gets SIGWINCH), and the view redraws. Colours, palette and cursor style apply on the next draw.
- (void)applyTheme:(COTTerminalTheme *)theme;
- (NSString *)selectedText;
- (void)copySelection;
- (void)pasteFromClipboard;
- (void)clearSelection;
- (void)selectAll;
- (NSDictionary *)performanceSnapshot;

@end

NS_ASSUME_NONNULL_END
