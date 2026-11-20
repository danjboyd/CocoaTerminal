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

/// Search through the scrollback and the screen. -findPrevious: looks up (towards older output) and -findNext: down;
/// both wrap round. A new text starts from the end, so -findPrevious: first finds the newest match. The match is
/// scrolled into view and selected (so -copySelection copies it). NO, with the selection cleared, when there's none.
- (BOOL)findPrevious:(NSString *)text;
- (BOOL)findNext:(NSString *)text;
/// Whether searches match case; NO (the default) ignores it for ASCII letters.
@property (nonatomic) BOOL findCaseSensitive;
/// A find field at the top right of the view (Ctrl+Shift+F, or Cmd+Shift+F on a Mac). Typing searches as you go;
/// Enter finds the next older match, Shift+Enter the next newer one, Esc closes it.
- (void)showFindBar;
- (void)hideFindBar;
@property (nonatomic, readonly, getter=isFindBarVisible) BOOL findBarVisible;

/// The link (http, https, ftp, file or mailto URL) shown at a cell of the view, or nil. Ctrl-click (Cmd-click on a
/// Mac) opens it with -openLink:.
- (nullable NSURL *)linkAtRow:(NSUInteger)row column:(NSUInteger)column;
/// Opens a link in the system's browser or mail program. A subclass can override it to open links its own way.
- (BOOL)openLink:(NSURL *)url;

/// Shell integration (OSC 133, see COTTerminalSession): scrolls so the previous (older) or next prompt is at the top of
/// the view; past the last prompt, -scrollToNextPrompt returns to the live screen. NO if there's no prompt that way.
/// Cmd+Shift+Up and Down (Ctrl+Shift on GNUstep) do the same.
- (BOOL)scrollToPreviousPrompt;
- (BOOL)scrollToNextPrompt;

@end

NS_ASSUME_NONNULL_END
