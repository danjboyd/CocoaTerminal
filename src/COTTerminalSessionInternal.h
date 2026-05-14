// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

#import <CocoaTerminal/COTTerminalSession.h>

#include "COTTerminalGrid.h"

#include <vector>

@interface COTTerminalSession (Internal)

- (const cot::TerminalGrid *)gridPointer;
- (NSArray<NSNumber *> *)takeDirtyRows;

@end
