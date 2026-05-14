// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import <CocoaTerminal/COTPlatform.h>

@class COTTerminalTheme;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, COTKeyboardCapturePolicy) {
  COTKeyboardCapturePolicyTerminalDefault = 0,
  COTKeyboardCapturePolicyHostPreferred = 1,
  COTKeyboardCapturePolicyTerminalExclusive = 2,
};

typedef NS_ENUM(NSInteger, COTTerminalExitBehavior) {
  COTTerminalExitBehaviorKeepOpen = 0,
  COTTerminalExitBehaviorCloseOwningWindow = 1,
  COTTerminalExitBehaviorTerminateApplication = 2,
};

@interface COTTerminalConfiguration : NSObject <NSCopying>

@property (nonatomic, copy) NSArray<NSString *> *shellCommand;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, copy) NSString *terminalType;
@property (nonatomic, retain) COTTerminalTheme *theme;
@property (nonatomic, retain) NSFont *font;
@property (nonatomic, retain) NSColor *foregroundColor;
@property (nonatomic, retain) NSColor *backgroundColor;
@property (nonatomic) NSUInteger scrollbackLineLimit;
@property (nonatomic) COTKeyboardCapturePolicy keyboardCapturePolicy;
@property (nonatomic) COTTerminalExitBehavior exitBehavior;

+ (instancetype)defaultConfiguration;

@end

NS_ASSUME_NONNULL_END
