// SPDX-License-Identifier: LGPL-2.1-or-later
// Private. Names that differ between macOS and GNUstep AppKit.
// The modifier, event and window-style names use the current spellings
// (NSEventModifierFlag*, NSEventType*, NSWindowStyleMask*). GNUstep defines
// those as the same values as its old names. The plain-text pasteboard type
// is the exception: GNUstep's NSPasteboardTypeString is a separate constant
// from NSStringPboardType, so GNUstep keeps the type it has always used.
#pragma once
#import <AppKit/AppKit.h>

#if defined(__APPLE__)
#define COTPasteboardTypeString NSPasteboardTypeString
#else
#define COTPasteboardTypeString NSStringPboardType
#endif
