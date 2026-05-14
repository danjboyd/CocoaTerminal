// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#import "COTConfigLoader.h"

static NSString *COTStripComment(NSString *line) {
  BOOL inSingle = NO;
  BOOL inDouble = NO;
  for (NSUInteger i = 0; i < [line length]; ++i) {
    unichar c = [line characterAtIndex:i];
    if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (c == '\'' && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '#' && !inSingle && !inDouble) {
      return [line substringToIndex:i];
    }
  }
  return line;
}

static NSString *COTUnescape(NSString *raw) {
  NSMutableString *out = [NSMutableString stringWithCapacity:[raw length]];
  NSUInteger i = 0;
  while (i < [raw length]) {
    unichar c = [raw characterAtIndex:i];
    if (c == '\\' && i + 1 < [raw length]) {
      unichar next = [raw characterAtIndex:i + 1];
      if (next == 'n') { [out appendString:@"\n"]; i += 2; continue; }
      if (next == 't') { [out appendString:@"\t"]; i += 2; continue; }
      if (next == 'r') { [out appendString:@"\r"]; i += 2; continue; }
      if (next == '\\') { [out appendString:@"\\"]; i += 2; continue; }
      if (next == '"') { [out appendString:@"\""]; i += 2; continue; }
    }
    [out appendFormat:@"%C", c];
    i += 1;
  }
  return out;
}

static NSArray *COTParseArray(NSString *value) {
  NSString *body = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([body length] < 2 || ![body hasPrefix:@"["] || ![body hasSuffix:@"]"]) {
    return nil;
  }
  body = [body substringWithRange:NSMakeRange(1, [body length] - 2)];
  NSMutableArray *result = [NSMutableArray array];
  NSUInteger i = 0;
  while (i < [body length]) {
    while (i < [body length]) {
      unichar c = [body characterAtIndex:i];
      if (c != ' ' && c != '\t' && c != ',') {
        break;
      }
      i += 1;
    }
    if (i >= [body length]) {
      break;
    }
    unichar quote = [body characterAtIndex:i];
    if (quote != '"' && quote != '\'') {
      return nil;
    }
    NSUInteger start = i + 1;
    NSUInteger j = start;
    while (j < [body length]) {
      unichar c = [body characterAtIndex:j];
      if (c == '\\' && quote == '"' && j + 1 < [body length]) {
        j += 2;
        continue;
      }
      if (c == quote) {
        break;
      }
      j += 1;
    }
    if (j >= [body length]) {
      return nil;
    }
    NSString *piece = [body substringWithRange:NSMakeRange(start, j - start)];
    if (quote == '"') {
      piece = COTUnescape(piece);
    }
    [result addObject:piece];
    i = j + 1;
  }
  return result;
}

static id COTParseValue(NSString *value) {
  NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([trimmed length] == 0) {
    return nil;
  }
  unichar first = [trimmed characterAtIndex:0];
  if (first == '"' || first == '\'') {
    if ([trimmed length] < 2 || [trimmed characterAtIndex:[trimmed length] - 1] != first) {
      return nil;
    }
    NSString *inside = [trimmed substringWithRange:NSMakeRange(1, [trimmed length] - 2)];
    if (first == '"') {
      inside = COTUnescape(inside);
    }
    return inside;
  }
  if (first == '[') {
    return COTParseArray(trimmed);
  }
  if ([trimmed isEqualToString:@"true"]) {
    return [NSNumber numberWithBool:YES];
  }
  if ([trimmed isEqualToString:@"false"]) {
    return [NSNumber numberWithBool:NO];
  }
  NSScanner *scanner = [NSScanner scannerWithString:trimmed];
  double doubleValue = 0;
  if ([scanner scanDouble:&doubleValue] && [scanner isAtEnd]) {
    if ([trimmed rangeOfString:@"."].location == NSNotFound &&
        [trimmed rangeOfString:@"e"].location == NSNotFound &&
        [trimmed rangeOfString:@"E"].location == NSNotFound) {
      return [NSNumber numberWithLongLong:(long long)doubleValue];
    }
    return [NSNumber numberWithDouble:doubleValue];
  }
  return trimmed;
}

static NSColor *COTColorFromHexString(NSString *hex) {
  NSString *trimmed = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([trimmed hasPrefix:@"#"]) {
    trimmed = [trimmed substringFromIndex:1];
  } else if ([trimmed hasPrefix:@"0x"] || [trimmed hasPrefix:@"0X"]) {
    trimmed = [trimmed substringFromIndex:2];
  } else {
    return nil;
  }
  if ([trimmed length] != 6) {
    return nil;
  }
  unsigned int hexValue = 0;
  NSScanner *scanner = [NSScanner scannerWithString:trimmed];
  if (![scanner scanHexInt:&hexValue]) {
    return nil;
  }
  CGFloat red = ((hexValue >> 16) & 0xff) / 255.0;
  CGFloat green = ((hexValue >> 8) & 0xff) / 255.0;
  CGFloat blue = (hexValue & 0xff) / 255.0;
  return [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0];
}

@implementation COTConfigLoader

+ (NSString *)defaultConfigPath {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *env = [[NSProcessInfo processInfo] environment];
  NSString *override = [env objectForKey:@"COCOATERMINAL_CONFIG"];
  if ([override length] > 0 && [fm fileExistsAtPath:override]) {
    return override;
  }
  NSString *home = NSHomeDirectory();
  NSString *xdg = [env objectForKey:@"XDG_CONFIG_HOME"];
  if ([xdg length] == 0) {
    xdg = [home stringByAppendingPathComponent:@".config"];
  }
  NSString *own = [[xdg stringByAppendingPathComponent:@"cocoaterminal"] stringByAppendingPathComponent:@"config.toml"];
  if ([fm fileExistsAtPath:own]) {
    return own;
  }
  NSString *alacritty = [[xdg stringByAppendingPathComponent:@"alacritty"] stringByAppendingPathComponent:@"alacritty.toml"];
  if ([fm fileExistsAtPath:alacritty]) {
    return alacritty;
  }
  return nil;
}

+ (NSDictionary *)loadFromPath:(NSString *)path {
  NSError *error = nil;
  NSString *content = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:&error];
  if (content == nil) {
    return nil;
  }
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSString *currentSection = @"";
  NSArray *lines = [content componentsSeparatedByString:@"\n"];
  for (NSString *rawLine in lines) {
    NSString *line = COTStripComment(rawLine);
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([line length] == 0) {
      continue;
    }
    if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
      NSString *header = [line substringWithRange:NSMakeRange(1, [line length] - 2)];
      currentSection = [header stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      continue;
    }
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      continue;
    }
    NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *rawValue = [line substringFromIndex:eq.location + 1];
    id value = COTParseValue(rawValue);
    if (value == nil) {
      continue;
    }
    NSString *fullKey = [currentSection length] > 0
                          ? [NSString stringWithFormat:@"%@.%@", currentSection, key]
                          : key;
    [result setObject:value forKey:fullKey];
  }
  return result;
}

+ (void)applyConfig:(NSDictionary *)config toConfiguration:(COTTerminalConfiguration *)terminalConfig {
  COTTerminalTheme *theme = [terminalConfig theme];

  NSNumber *fontSize = [config objectForKey:@"font.size"];
  if ([fontSize isKindOfClass:[NSNumber class]]) {
    [theme setFontSize:[fontSize doubleValue]];
  }
  NSString *fontFamily = [config objectForKey:@"font.normal.family"];
  if ([fontFamily isKindOfClass:[NSString class]] && [fontFamily length] > 0) {
    [theme setFontFamily:fontFamily];
  }

  NSString *shellProgram = [config objectForKey:@"shell.program"];
  if (![shellProgram isKindOfClass:[NSString class]]) {
    shellProgram = [config objectForKey:@"terminal.shell.program"];
  }
  NSArray *shellArgs = [config objectForKey:@"shell.args"];
  if (![shellArgs isKindOfClass:[NSArray class]]) {
    shellArgs = [config objectForKey:@"terminal.shell.args"];
  }
  if ([shellProgram isKindOfClass:[NSString class]] && [shellProgram length] > 0) {
    NSMutableArray *command = [NSMutableArray arrayWithObject:shellProgram];
    if ([shellArgs isKindOfClass:[NSArray class]]) {
      for (id arg in shellArgs) {
        if ([arg isKindOfClass:[NSString class]]) {
          [command addObject:arg];
        }
      }
    }
    [terminalConfig setShellCommand:command];
  }

  NSString *fgHex = [config objectForKey:@"colors.primary.foreground"];
  if ([fgHex isKindOfClass:[NSString class]]) {
    NSColor *color = COTColorFromHexString(fgHex);
    if (color != nil) {
      [theme setForegroundColor:color];
    }
  }
  NSString *bgHex = [config objectForKey:@"colors.primary.background"];
  if ([bgHex isKindOfClass:[NSString class]]) {
    NSColor *color = COTColorFromHexString(bgHex);
    if (color != nil) {
      [theme setBackgroundColor:color];
    }
  }
  NSString *cursorHex = [config objectForKey:@"colors.cursor.cursor"];
  if ([cursorHex isKindOfClass:[NSString class]]) {
    NSColor *color = COTColorFromHexString(cursorHex);
    if (color != nil) {
      [theme setCursorColor:color];
    }
  }

  NSNumber *opacity = [config objectForKey:@"window.opacity"];
  if ([opacity isKindOfClass:[NSNumber class]]) {
    double value = [opacity doubleValue];
    if (value < 0.0) value = 0.0;
    if (value > 1.0) value = 1.0;
    [theme setOpacity:value];
  }

  NSNumber *history = [config objectForKey:@"scrolling.history"];
  if ([history isKindOfClass:[NSNumber class]]) {
    NSInteger value = [history integerValue];
    if (value < 0) value = 0;
    [terminalConfig setScrollbackLineLimit:(NSUInteger)value];
  }
}

@end
