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

typedef NS_ENUM(NSInteger, COTTerminalInputPolicy) {
  COTTerminalInputPolicyInteractive = 0,
  COTTerminalInputPolicyObserve = 1,
};
typedef NS_ENUM(NSInteger, COTTerminalSizingPolicy) {
  COTTerminalSizingPolicyFollowView = 0,
  COTTerminalSizingPolicyFixedGrid = 1,
};

@interface COTTerminalConfiguration : NSObject <NSCopying>

@property (nonatomic, copy) NSArray<NSString *> *shellCommand;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, copy) NSString *workingDirectory;
@property (nonatomic, copy) NSString *terminalType;
@property (nonatomic, retain) COTTerminalTheme *theme;
@property (nonatomic, retain) NSFont *font;
@property (nonatomic, retain) NSColor *foregroundColor;
@property (nonatomic, retain) NSColor *backgroundColor;
@property (nonatomic) NSUInteger scrollbackLineLimit;
@property (nonatomic) COTKeyboardCapturePolicy keyboardCapturePolicy;
@property (nonatomic) COTTerminalExitBehavior exitBehavior;

// Session construction freezes these policies and dimensions. Invalid values
// reject construction; changing a configuration cannot promote an observer.
@property (nonatomic) COTTerminalInputPolicy inputPolicy;
@property (nonatomic) COTTerminalSizingPolicy sizingPolicy;
@property (nonatomic) NSUInteger initialColumns;
@property (nonatomic) NSUInteger initialRows;

+ (instancetype)defaultConfiguration;

@end

NS_ASSUME_NONNULL_END
