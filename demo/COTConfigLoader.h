// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

#import <CocoaTerminal/CocoaTerminal.h>

NS_ASSUME_NONNULL_BEGIN

// Loads a small TOML subset compatible with Alacritty's config schema and
// applies it to a COTTerminalConfiguration. Supported keys:
//   font.size                      (number)
//   font.normal.family             (string)
//   shell.program                  (string)
//   shell.args                     (array of strings)
//   terminal.shell.program / args  (same, newer Alacritty schema)
//   colors.primary.foreground      (hex string, "#rrggbb" or "0xrrggbb")
//   colors.primary.background      (hex string)
//   colors.cursor.text             (hex string)
//   colors.cursor.cursor           (hex string)
//   window.opacity                 (number 0..1)
//   scrolling.history              (integer)
@interface COTConfigLoader : NSObject

// Resolves the config file by searching:
//   1. $COCOATERMINAL_CONFIG (if set and exists)
//   2. $XDG_CONFIG_HOME/cocoaterminal/config.toml (or ~/.config/cocoaterminal/config.toml)
//   3. ~/.config/alacritty/alacritty.toml
// Returns nil if no config file is present.
+ (nullable NSString *)defaultConfigPath;

// Parses a TOML file. Returns a flat dictionary with dotted keys
// (e.g. "font.size", "colors.primary.foreground"). Values are NSString,
// NSNumber, or NSArray<NSString *>.
+ (nullable NSDictionary<NSString *, id> *)loadFromPath:(NSString *)path;

// Applies parsed values to the given configuration. Unknown keys are ignored.
+ (void)applyConfig:(NSDictionary<NSString *, id> *)config
    toConfiguration:(COTTerminalConfiguration *)terminalConfig;

@end

NS_ASSUME_NONNULL_END
