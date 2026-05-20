// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

#import <CocoaTerminal/COTTerminalSession.h>

#include "COTTerminalGrid.h"

#include <vector>

@interface COTTerminalSnapshot : NSObject {
@public
  std::vector<std::vector<cot::TerminalCell>> cells;
  std::vector<std::string> lines;
  NSUInteger columns;
  NSUInteger rows;
  NSUInteger cursorColumn;
  NSUInteger cursorRow;
  BOOL cursorVisible;
  BOOL usingAlternateScreen;
  BOOL hasUsedAlternateScreen;
  BOOL hasColorSpans;
  BOOL hasUnicode;
  BOOL mouseReportingEnabled;
  BOOL mouseButtonMotionReportingEnabled;
  BOOL mouseAnyMotionReportingEnabled;
  BOOL sgrMouseModeEnabled;
  BOOL alternateScrollModeEnabled;
  BOOL bracketedPasteEnabled;
  BOOL focusReportingEnabled;
  NSUInteger scrollbackLineCount;
  NSUInteger viewportOffset;
  NSUInteger maxViewportOffset;
  std::vector<bool> dirtyRows;
  BOOL fullRedraw;
  NSString *title;
}
@end

@interface COTTerminalSession (Internal)

- (COTTerminalSnapshot *)currentSnapshot;
- (NSArray<NSNumber *> *)takeDirtyRows;

@end
